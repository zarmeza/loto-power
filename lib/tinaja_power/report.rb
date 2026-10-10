# frozen_string_literal: true

require 'time'

module TinajaPower
  # Turns the interval history into numbers a person can act on.
  #
  # Two decisions shape everything here.
  #
  # An outage is a stretch of time the laptop was on battery. That is the whole rule, and
  # it is deliberately not "AC off AND the router died": the router here is a cellular CPE
  # that may well have its own battery, so losing the internet is not proof of losing
  # power. It is recorded next to the outage as context instead, never as a filter.
  #
  # Percentages are always over observed time. Time the laptop was off or asleep cannot be
  # attributed to anything, so it is reported separately and never silently added to
  # either side of the ratio.
  class Report
    # One stretch of time on battery.
    Outage = Data.define(:from_ts, :to_ts, :seconds, :battery_pct_at_start, :charge_wh_at_start,
                         :net_blackout_seconds) do
      def ended?(before) = to_ts && to_ts <= before
      def net_known? = !net_blackout_seconds.nil?
      def net_kept? = net_blackout_seconds && net_blackout_seconds < seconds
    end

    Summary = Data.define(:window_seconds, :observed_seconds, :unknown_seconds, :on_ac_seconds,
                          :outage_seconds, :outages) do
      def longest_seconds = outages.map(&:seconds).max || 0.0
      def coverage_ratio = window_seconds.zero? ? nil : observed_seconds / window_seconds

      # Over observed time only. Over the window it would be a lie dressed as a percentage.
      def outage_ratio = observed_seconds.zero? ? nil : outage_seconds / observed_seconds
      def outage_count = outages.length
    end

    def initialize(store)
      @store = store
    end

    def summary(since: nil, before: Time.now.to_f)
      clipped = clipped_intervals(since, before)
      outages = outages_from(clipped)

      Summary.new(
        window_seconds: clipped.sum { |c| c[:to] - c[:from] },
        observed_seconds: clipped.reject { |c| c[:interval].unknown? }.sum { |c| c[:to] - c[:from] },
        unknown_seconds: clipped.select { |c| c[:interval].unknown? }.sum { |c| c[:to] - c[:from] },
        on_ac_seconds: clipped.select { |c| c[:interval].on_ac? }.sum { |c| c[:to] - c[:from] },
        outage_seconds: outages.sum(&:seconds),
        outages: outages
      )
    end

    # Outages oldest first, like the history they come from. A limit keeps the most recent
    # ones but does not reorder them; reversing for display is the caller's business.
    def outages(since: nil, before: Time.now.to_f, limit: nil)
      found = summary(since:, before:).outages
      limit ? found.last(limit) : found
    end

    def as_json(since: nil, before: Time.now.to_f, limit: nil)
      data = summary(since:, before:)
      {
        window: {
          from: since ? Time.at(since).utc.iso8601 : nil,
          to: Time.at(before).utc.iso8601,
          seconds: data.window_seconds.round(1),
          observed_seconds: data.observed_seconds.round(1),
          unknown_seconds: data.unknown_seconds.round(1),
          coverage: data.coverage_ratio&.round(4)
        },
        totals: {
          on_ac_seconds: data.on_ac_seconds.round(1),
          outage_seconds: data.outage_seconds.round(1),
          outage_count: data.outage_count,
          longest_outage_seconds: data.longest_seconds.round(1),
          outage_ratio_of_observed: data.outage_ratio&.round(4)
        },
        outages: (limit ? data.outages.last(limit) : data.outages).map { |o| outage_json(o) }
      }
    end

    private

    # An outage that began before the window is still part of the window, so intervals are
    # trimmed to it rather than counted whole. Without this, asking about the last hour
    # during a nine-hour outage would report nine hours.
    def clipped_intervals(since, before)
      @store.intervals(since:, before:).filter_map do |interval|
        from = [interval.from_ts, since].compact.max
        to = [interval.to_ts || before, before].min
        next if to <= from

        { interval:, from:, to: }
      end
    end

    def outages_from(clipped)
      clipped.select { |c| c[:interval].on_battery? }.map do |c|
        interval = c[:interval]
        Outage.new(
          from_ts: c[:from],
          to_ts: interval.to_ts,
          seconds: c[:to] - c[:from],
          battery_pct_at_start: interval.battery_pct,
          charge_wh_at_start: interval.charge_wh,
          net_blackout_seconds: net_blackout_within(interval, c[:from], c[:to])
        )
      end
    end

    # How long the internet was actually down inside one outage, or nil when the journal of
    # reachability does not cover it.
    #
    # Nil is a real answer here and it is the honest one: history seeded from the journal
    # knows nothing about the router, and reporting the whole outage as "internet down"
    # because we never heard otherwise would invent a second outage out of the first.
    #
    # Otherwise the state is replayed forward from whatever the interval started with.
    def net_blackout_within(interval, from, to)
      return nil if interval.has_route.nil?

      events = @store.net_events(since: interval.from_ts).select { |e| e.ts >= from && e.ts < to }
      reachable = interval.has_route == 1
      blacked_out = 0.0
      cursor = from

      events.each do |event|
        blacked_out += event.ts - cursor unless reachable
        reachable = event.has_route
        cursor = event.ts
      end
      blacked_out += to - cursor unless reachable
      blacked_out
    end

    def outage_json(outage)
      {
        from: Time.at(outage.from_ts).utc.iso8601,
        to: outage.to_ts ? Time.at(outage.to_ts).utc.iso8601 : nil,
        seconds: outage.seconds.round(1),
        battery_pct_at_start: outage.battery_pct_at_start,
        charge_wh_at_start: outage.charge_wh_at_start,
        net_blackout_seconds: outage.net_blackout_seconds&.round(1)
      }
    end
  end
end
