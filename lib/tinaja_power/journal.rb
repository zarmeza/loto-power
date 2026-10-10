# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

require_relative 'format'

module TinajaPower
  # Seeds the history from the journal's AC adapter messages.
  #
  # Be clear about what this is worth. The kernel logs "AC Adapter [ADP1] (off-line)" when
  # it probes the adapter at boot and when the machine is running with no power. On this
  # laptop, every off-line line in ten days of journal was a boot line, because the laptop
  # spends a third of its life switched off and cannot witness its own outages.
  #
  # So backfill is not a history. What it is worth is the unknown stretches: it tells the
  # report that the machine was not watching between two points in time, which is the
  # difference between a coverage figure that means something and one that starts at zero
  # today. It is also the proof that the journal path works, if a future kernel does log
  # transitions at runtime.
  module Journal
    Event = Data.define(:ts, :online)

    ONLINE = /AC Adapter \[(\w+)\] \(on-line\)/
    OFFLINE = /AC Adapter \[(\w+)\] \(off-line\)/

    module_function

    # Reads the whole journal as JSON lines and keeps the adapter transitions.
    def ac_events(adapter: 'ADP1')
      pairs = []
      # --no-pager, one JSON object per line, so a line is an event rather than a screenful.
      stdout, status = Open3.capture2('journalctl', '--no-pager', '-o', 'json', '--output-fields',
                                      'MESSAGE,__REALTIME_TIMESTAMP')
      raise "journalctl failed: #{status}" unless status.success?

      stdout.each_line do |line|
        next if line.strip.empty?

        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        message = entry['MESSAGE'].to_s
        adapter_name = ONLINE.match(message)&.captures&.first ||
                       OFFLINE.match(message)&.captures&.first
        next unless adapter_name == adapter

        # __REALTIME_TIMESTAMP is microseconds since the epoch, which is what journal gives.
        pairs << Event.new(entry.fetch('__REALTIME_TIMESTAMP').to_i / 1_000_000.0,
                           OFFLINE.match(message).nil?)
      end
      pairs.sort_by(&:ts)
    end

    # Turns the events into contiguous segments spanning the whole range they cover.
    #
    # An on-line event is NOT extended into an on-AC interval. The kernel only logs the
    # adapter at boot, so between two on-line lines the laptop may well have been switched
    # off, and saying it was on AC throughout would be inventing history — and would do it
    # in the direction that flatters the numbers. A gap in the journal is unknown, so that
    # is what a gap becomes.
    #
    # An off-line event is direct evidence: the kernel looked at the adapter and it was not
    # there. That one is trusted.
    def segments(events)
      return [] if events.length < 2

      events.each_cons(2).map do |first, second|
        [first.ts, second.ts, first.online ? nil : 0]
      end
    end

    # Writes the segments. Time before the first event and after the last is left
    # unrecorded: the journal does not say what the adapter was doing then, and saying
    # otherwise would be inventing history.
    def backfill(store, events)
      if events.empty?
        return 'No AC adapter events in the journal, so there is nothing to seed.'
      end

      seeded = store.seed(segments(events))
      outages = events.each_cons(2).count { |a, b| !a.online }
      "#{seeded} intervals written over #{Format.duration(events.last.ts - events.first.ts)}. " \
        "#{outages} #{outages == 1 ? 'stretch' : 'stretches'} on battery are supported by the journal; " \
        'the rest is unknown, because the kernel only logs the adapter at boot.'
    end
  end
end
