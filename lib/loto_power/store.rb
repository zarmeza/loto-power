# frozen_string_literal: true

require 'fileutils'
require 'sqlite3'

module LotoPower
  # The history, as intervals rather than samples.
  #
  # A sample every thirty seconds would be four thousand rows a day to answer questions
  # about an event that happened twice. An interval is one row per contiguous stretch of
  # time in one state, so the history is exact and the report is a sum.
  #
  # The one rule this class exists to enforce: ac_online is tri-state. 1 is on AC, 0 is on
  # battery, and NULL is we were not watching. NULL is neither zero nor one, and nothing
  # downstream is allowed to quietly fold it into "on AC". When this process is not running
  # the laptop is off, asleep or rebooting, and the tool does not get to guess what the
  # office was doing.
  class Store
    Interval = Data.define(:id, :from_ts, :to_ts, :ac_online, :battery_pct, :charge_wh, :has_route) do
      def open? = to_ts.nil?
      def unknown? = ac_online.nil?
      def on_ac? = ac_online == 1
      def on_battery? = ac_online == 0

      # Length so far. The open interval has not finished, so it is measured against now.
      def seconds(now) = (to_ts || now) - from_ts
    end

    NetEvent = Data.define(:ts, :has_route)

    SCHEMA_VERSION = '1'

    # Ten missed timer fires. Long enough to ride out a boot or the suspend failures this
    # machine has had, short enough that a real outage does not go unrecorded.
    DEFAULT_GAP = 300.0

    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS interval (
        id          INTEGER PRIMARY KEY,
        from_ts     REAL NOT NULL,
        to_ts       REAL,             -- NULL means still open; at most one such row
        ac_online   INTEGER,          -- 1 on AC, 0 on battery, NULL unobserved
        battery_pct INTEGER,          -- context at the moment this state began
        charge_wh   REAL,
        has_route   INTEGER
      );
      CREATE INDEX IF NOT EXISTS interval_from_ts ON interval(from_ts);

      CREATE TABLE IF NOT EXISTS net_event (
        id        INTEGER PRIMARY KEY,
        ts        REAL NOT NULL,
        has_route INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS net_event_ts ON net_event(ts);

      CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
    SQL

    # Raised when the wall clock jumps backwards, which would otherwise let intervals
    # overlap and quietly corrupt every total derived from them.
    class ClockWentBackwards < StandardError; end

    # Raised when seeded history would land on top of history this store already has.
    class SeedOverlapsHistory < StandardError; end

    # Fills in history from events that happened before this store was watching.
    #
    # Deliberately not `record`. record refuses to write the past, because for a live
    # recorder a backwards timestamp means the clock stepped and the write is a bug. The
    # journal is the opposite: it is entirely in the past by definition, and refusing it
    # would make backfill impossible on any database that had already started recording.
    #
    # segments are [from_ts, to_ts, ac_online] triples, sorted and contiguous. The gap
    # between the end of the seeded history and the start of what was already recorded is
    # bridged with an explicit unknown interval, because that stretch is exactly the time
    # nobody was watching.
    def seed(segments)
      raise ArgumentError, 'nothing to seed' if segments.empty?

      seed_from, seed_to = segments.first[0], segments.last[1]
      existing = intervals(since: nil, before: Float::INFINITY)

      clash = existing.find { |i| i.from_ts < seed_to && (i.to_ts || Float::INFINITY) > seed_from }
      if clash
        raise SeedOverlapsHistory,
              "the journal covers #{Time.at(seed_from)} to #{Time.at(seed_to)}, which overlaps an " \
              'interval this database already has. Seed before the first `loto-power record`, ' \
              'or remove the database and start again.'
      end

      watching_started = existing.map { |i| i.to_ts || i.from_ts }.min
      segments += [[seed_to, watching_started, nil]] if watching_started && watching_started > seed_to

      transaction do
        segments.each { |(from, to, ac)| insert_interval(from, to, ac, nil) }
      end
      segments.length
    end

    COLUMNS = 'id, from_ts, to_ts, ac_online, battery_pct, charge_wh, has_route'

    attr_reader :path

    def initialize(path)
      @path = path
      FileUtils.mkdir_p(File.dirname(path))
      @db = SQLite3::Database.new(path)
      @db.execute_batch('PRAGMA journal_mode = WAL;')
      @db.execute_batch(SCHEMA)
      write_meta('schema_version', SCHEMA_VERSION)
    end

    def close = @db.close

    # Folds one look at the machine into the history. Safe to call as often as you like:
    # a second call that sees the same state writes nothing at all.
    #
    # Returns :recorded when an interval was opened, :unchanged when the machine was
    # already in this state, and :gap when contact was lost and a stretch of unknown time
    # had to be written because the laptop was not watching.
    def record(reading, at: Time.now.to_f, gap: DEFAULT_GAP)
      last = meta('last_record_at')&.to_f
      raise ClockWentBackwards, "#{at} precedes the last record at #{last}" if last && at < last

      current = open_interval
      outcome = :unchanged

      # We were away too long. Whatever happened between the last sighting and now went
      # unobserved, so it becomes an explicit unknown rather than an extension of
      # whatever state we happened to be in before we disappeared.
      if last && (at - last) > gap
        close_interval(current, last) if current
        insert_interval(last, at, nil, nil)
        current = nil
        outcome = :gap
      end

      ac = tri_state(reading.ac_online)
      if current.nil? || current.ac_online != ac
        close_interval(current, at) if current
        insert_interval(at, nil, ac, reading)
        outcome = :recorded unless outcome == :gap
      end

      note_net_event(at, reading.has_route)
      write_meta('last_record_at', at)
      write_meta('last_has_route', tri_state(reading.has_route))

      outcome
    end

    # Intervals overlapping the window, oldest first. Intervals are half-open, [from, to),
    # so `before` is exclusive: an interval that begins exactly at it belongs to the next
    # window, not this one.
    #
    # The open interval comes back too, with to_ts still nil. Callers measure it against
    # their own now rather than pretending it has ended.
    def intervals(since: nil, before: Time.now.to_f)
      sql = +"SELECT #{COLUMNS} FROM interval"
      where = []
      args = []
      where << 'to_ts IS NULL OR to_ts > ?' if since
      args << since if since
      where << 'from_ts < ?' if before
      args << before if before
      sql << " WHERE #{where.join(' AND ')}" unless where.empty?
      sql << ' ORDER BY from_ts'

      @db.execute(sql, args).map { |row| Interval.new(*row) }
    end

    def open_interval
      row = @db.get_first_row("SELECT #{COLUMNS} FROM interval WHERE to_ts IS NULL LIMIT 1")
      row && Interval.new(*row)
    end

    def net_events(since: nil)
      sql = +'SELECT ts, has_route FROM net_event'
      args = []
      if since
        sql << ' WHERE ts >= ?'
        args << since
      end
      sql << ' ORDER BY ts'
      # SQLite hands back 0 and 1, and 0 is truthy in Ruby. Convert at the boundary so a
      # caller writing `if event.has_route` gets the answer they meant.
      @db.execute(sql, args).map { |row| NetEvent.new(row[0], row[1] == 1) }
    end

    def meta(key)
      @db.get_first_value('SELECT v FROM meta WHERE k = ?', [key])
    end

    private

    def transaction(&block)
      @db.transaction(&block)
    end

    # Reachability is recorded only when it changes, so an outage keeps its shape: when
    # the internet went, and when it came back.
    def note_net_event(at, has_route)
      state = tri_state(has_route)
      return if state.nil? || meta('last_has_route') == state.to_s

      @db.execute('INSERT INTO net_event (ts, has_route) VALUES (?, ?)', [at, state])
    end

    def insert_interval(from_ts, to_ts, ac_online, reading)
      @db.execute(
        'INSERT INTO interval (from_ts, to_ts, ac_online, battery_pct, charge_wh, has_route)
         VALUES (?, ?, ?, ?, ?, ?)',
        [from_ts, to_ts, ac_online, reading&.battery_pct, reading&.charge_wh,
         reading && tri_state(reading.has_route)]
      )
    end

    # Named close_interval rather than close, because close is the database's.
    def close_interval(interval, at)
      @db.execute('UPDATE interval SET to_ts = ? WHERE id = ?', [at, interval.id])
    end

    # Ruby booleans are not SQLite integers, and nil has to stay nil rather than become 0.
    def tri_state(value)
      return nil if value.nil?

      value ? 1 : 0
    end

    def write_meta(key, value)
      @db.execute('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v',
                  [key, value.to_s])
    end
  end
end
