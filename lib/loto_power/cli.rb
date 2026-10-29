# frozen_string_literal: true

require 'json'
require 'optparse'
require 'pathname'
require 'time'

require_relative 'format'
require_relative 'report'
require_relative 'store'
require_relative 'sysfs'

module LotoPower
  # The command line. Everything in this gem is reachable from here, and everything here
  # is meant to be reachable by a subprocess: another program asking this tool a question
  # should never have to know how the database is shaped.
  class CLI
    DEFAULT_DB = '~/.local/share/loto-power/power.db'
    DB_ENV = 'LOTO_POWER_DB'

    EXIT_OK = 0
    EXIT_USAGE = 1
    EXIT_FAILED = 2

    UNITS = { 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86_400, 'w' => 604_800 }.freeze

    COMMANDS = %w[record status report backfill].freeze

    def self.start(argv, out: $stdout, err: $stderr)
      new(out:, err:).run(argv)
    end

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def run(argv)
      argv = argv.dup
      command = argv.shift
      return usage if command.nil? || %w[-h --help help].include?(command)
      return usage("unknown command #{command.inspect}") unless COMMANDS.include?(command)

      # The run_* methods are private on purpose; run is the only public way in.
      send("run_#{command}", argv)
    rescue OptionParser::ParseError => e
      @err.puts "loto-power: #{e.message}"
      EXIT_USAGE
    rescue Store::ClockWentBackwards => e
      @err.puts "loto-power: refusing to record — #{e.message}"
      @err.puts 'loto-power: this usually means the clock stepped; check chrony before trusting the history'
      EXIT_FAILED
    end

    private

    def run_record(argv)
      options = { gap: Store::DEFAULT_GAP, verbose: false }
      return EXIT_OK if parse!(argv, 'record', options) do |p|
        p.on('--gap SECONDS', Float, 'treat a longer silence as unobserved (default 300)') do |v|
          options[:gap] = v
        end
        p.on('-v', '--verbose', 'say something even when nothing changed') { options[:verbose] = true }
      end

      with_store(options[:db]) do |store|
        outcome = store.record(Sysfs.new.reading, at: Time.now.to_f, gap: options[:gap])
        @out.puts describe(outcome) if outcome != :unchanged || options[:verbose]
      end
      EXIT_OK
    end

    def describe(outcome)
      case outcome
      when :recorded then 'recorded — the state changed'
      when :gap then 'recorded — the laptop was away, so that time is now marked unknown'
      else 'no change'
      end
    end

    def run_status(argv)
      options = { json: false }
      return EXIT_OK if parse!(argv, 'status', options) do |p|
        p.on('--json', 'machine-readable output') { options[:json] = true }
      end

      reading = Sysfs.new.reading
      if options[:json]
        @out.puts JSON.pretty_generate(
          ac_online: reading.ac_online,
          battery_pct: reading.battery_pct,
          charge_wh: reading.charge_wh,
          has_route: reading.has_route,
          iface: reading.iface
        )
      else
        @out.puts Format.status(reading)
      end
      EXIT_OK
    end

    def run_report(argv)
      options = { json: false, since: nil, before: nil, limit: nil }
      return EXIT_OK if parse!(argv, 'report', options) do |p|
        p.on('--since DURATION', 'look back, e.g. 7d, 36h, 2w') do |v|
          options[:since] = parse_duration(v)
        end
        p.on('--before TIME', 'stop looking before this, e.g. 2026-10-01') do |v|
          options[:before] = parse_time(v)
        end
        p.on('-n', '--limit N', Integer, 'only the N most recent outages') { |v| options[:limit] = v }
        p.on('--json', 'machine-readable output') { options[:json] = true }
      end

      with_store(options[:db]) do |store|
        report = Report.new(store)
        since = options[:since] ? Time.now.to_f - options[:since] : nil
        before = options[:before] || Time.now.to_f
        @out.puts(if options[:json]
                   JSON.pretty_generate(report.as_json(since:, before:, limit: options[:limit]))
                 else
                   render(report, since:, before:, limit: options[:limit])
                 end)
      end
      EXIT_OK
    end

    def run_backfill(argv)
      options = {}
      return EXIT_OK if parse!(argv, 'backfill', options)
      require_relative 'journal'

      with_store(options[:db]) do |store|
        events = Journal.ac_events
        @out.puts "Found #{events.length} AC adapter events in the journal."
        @out.puts Journal.backfill(store, events)
      end
      EXIT_OK
    end

    # Builds a parser, runs it, and reports whether there is any work left to do. Prints
    # help and returns true when --help was asked for.
    #
    # --db is declared here rather than per command so that every command accepts it and
    # every help text mentions it, which is what the top-level usage promises.
    def parse!(argv, command, options)
      parser = OptionParser.new do |p|
        p.banner = "Usage: loto-power #{command} [options]"
        p.on('--db PATH', "database to use (default $#{DB_ENV}, or #{DEFAULT_DB})") do |v|
          options[:db] = v
        end
        yield p if block_given?
        p.on('-h', '--help', 'show this') { @out.puts p; throw :halt, true }
      end
      catch(:halt) { parser.parse!(argv); false }
    end

    # --- output ---------------------------------------------------------------------------

    def render(report, since:, before:, limit:)
      data = report.summary(since:, before:)
      shown = limit ? data.outages.last(limit) : data.outages
      lines = data.outage_count.zero? ? [] : shown.reverse.map { |outage| outage_line(outage, before) }
      # Without this, listing one outage under a heading that totals three reads as though
      # the other two never happened.
      lines << "  (showing #{shown.length} of #{data.outage_count})" if shown.length < data.outage_count

      (lines + [''] + totals(data) + [coverage(data)]).join("\n")
    end

    def outage_line(outage, before)
      text = +"  #{Format.clock(outage.from_ts)}  "
      text << (outage.ended?(before) ? "→ #{Format.clock(outage.to_ts)}" : '→ still on battery')
      text << "  #{Format.duration(outage.seconds)}"
      text << "  started at #{outage.battery_pct_at_start}%" if outage.battery_pct_at_start
      if outage.net_blackout_seconds&.positive?
        text << "  internet down #{Format.duration(outage.net_blackout_seconds)}"
      end
      text
    end

    def totals(data)
      lines = []
      if data.outage_count.zero?
        lines << 'Never on battery.'
      else
        lines << "#{data.outage_count} #{plural(data.outage_count, 'outage')}, " \
                 "#{Format.duration(data.outage_seconds)} on battery, longest " \
                 "#{Format.duration(data.longest_seconds)}."
      end
      lines << "On battery #{Format.percent(data.outage_ratio)} of observed time."
      lines
    end

    # The line that keeps everything above it honest. Without it every number reads as if
    # it described the whole period, which for a laptop that spends a third of its life
    # switched off, it does not.
    def coverage(data)
      if data.coverage_ratio.nil?
        'Nothing has been recorded yet.'
      elsif data.coverage_ratio >= 0.999
        'Observed the whole period.'
      else
        "Observed #{Format.duration(data.observed_seconds)} of #{Format.duration(data.window_seconds)} " \
          "(#{Format.percent(data.coverage_ratio)}). The other " \
          "#{Format.duration(data.unknown_seconds)} is unknown — the laptop was off, asleep or rebooting."
      end
    end

    def plural(count, word)      count == 1 ? word : "#{word}s"
    end

    # --- plumbing -------------------------------------------------------------------------

    def with_store(db)
      store = Store.new(Pathname(db || ENV.fetch(DB_ENV, DEFAULT_DB)).expand_path)
      yield store
    ensure
      store&.close
    end

    # Accepts 7d, 36h, 90m, 2w, or a bare number of seconds.
    def parse_duration(text)
      match = /\A(\d+(?:\.\d+)?)\s*([smhdw]?)\z/i.match(text.strip)
      raise OptionParser::InvalidArgument, "cannot read #{text.inspect} as a duration" unless match

      match[1].to_f * UNITS.fetch(match[2].downcase, 1)
    end

    def parse_time(text)
      Time.parse(text).to_f
    rescue ArgumentError
      raise OptionParser::InvalidArgument, "cannot read #{text.inspect} as a time"
    end

    def usage(problem = nil)
      @err.puts "loto-power: #{problem}" if problem
      @out.puts(<<~TEXT)
        loto-power — records when the office loses power

        Usage: loto-power <command> [options]

          record     look at the machine now and fold it into the history
          status     what the machine looks like right now
          report     the outage history, with how much of it was actually observed
          backfill   seed the history from the journal's AC adapter messages

        Every command takes --db PATH. The default is $#{DB_ENV}, or #{DEFAULT_DB}.

        Run `loto-power <command> --help` for the rest.
      TEXT
      problem ? EXIT_USAGE : EXIT_OK
    end
  end
end
