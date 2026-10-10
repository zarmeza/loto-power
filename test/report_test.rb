# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'pathname'
require 'tmpdir'
require_relative '../lib/tinaja_power/report'
require_relative '../lib/tinaja_power/store'

class ReportTest < Minitest::Test
  T0 = 1_760_000_000.0
  HOUR = 3600.0

  Reading = Data.define(:ac_online, :battery_pct, :charge_wh, :has_route)
  WATCHING = 1_000_000.0

  def setup
    @dir = Pathname(Dir.mktmpdir('tinaja-power-report'))
    @store = TinajaPower::Store.new(@dir + 'power.db')
    @report = TinajaPower::Report.new(@store)
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@dir) if @dir.exist?
  end

  def record(ac:, at:, pct: 88, route: true)
    @store.record(Reading.new(ac_online: ac, battery_pct: pct, charge_wh: 2.5, has_route: route),
                  at:, gap: WATCHING)
  end

  def summary(**kwargs) = @report.summary(**kwargs)

  # --- nothing recorded yet --------------------------------------------------------------

  def test_an_empty_history_reports_nothing_rather_than_zero_uptime
    data = summary(before: T0)
    assert_equal 0, data.window_seconds
    assert_equal 0, data.outage_count
    assert_nil data.coverage_ratio
    assert_nil data.outage_ratio
  end

  # --- what counts as an outage -----------------------------------------------------------

  def test_time_on_battery_is_an_outage
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR)
    record(ac: true, at: T0 + 3 * HOUR)

    data = summary(before: T0 + 3 * HOUR)
    assert_equal 1, data.outage_count
    assert_equal 2 * HOUR, data.outages.first.seconds
  end

  def test_ac_lost_while_the_internet_stayed_up_is_still_an_outage
    # The rule is the charger, not the router. A cellular CPE can hold the link up on its
    # own battery, and calling that "not an outage" would miss exactly the outages where
    # the router was on a UPS.
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR, route: true)
    record(ac: true, at: T0 + 2 * HOUR)

    data = summary(before: T0 + 2 * HOUR)
    assert_equal 1, data.outage_count
    assert_equal HOUR, data.outages.first.seconds
    assert_equal 0, data.outages.first.net_blackout_seconds
  end

  def test_an_outage_keeps_the_network_context_it_had
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR, route: false)   # the router died with the power
    record(ac: false, at: T0 + 2 * HOUR, route: true)  # and came back an hour in
    record(ac: true, at: T0 + 4 * HOUR)

    outage = summary(before: T0 + 4 * HOUR).outages.first
    assert_equal 3 * HOUR, outage.seconds
    assert_equal HOUR, outage.net_blackout_seconds
    assert outage.net_kept?
  end

  def test_an_outage_with_no_record_of_the_network_does_not_claim_one
    # History seeded from the journal knows nothing about the router. Reporting the whole
    # outage as "internet down" because we never heard otherwise would invent a second
    # outage out of the first.
    @store.seed([[T0, T0 + 4 * HOUR, 0]])

    outage = summary(before: T0 + 4 * HOUR).outages.first
    assert_nil outage.net_blackout_seconds
    refute outage.net_known?
    assert_nil @report.as_json(before: T0 + 4 * HOUR)[:outages].first[:net_blackout_seconds]
  end

  def test_an_outage_that_begins_before_the_window_is_still_counted
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR)
    record(ac: true, at: T0 + 10 * HOUR)

    data = summary(since: T0 + 8 * HOUR, before: T0 + 10 * HOUR)
    assert_equal 1, data.outage_count
  end

  def test_an_outage_is_clipped_to_the_window_it_is_asked_about
    # Asking about the last hour of a nine-hour outage must not report nine hours.
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR)
    record(ac: true, at: T0 + 10 * HOUR)

    data = summary(since: T0 + 9 * HOUR, before: T0 + 10 * HOUR)
    assert_equal 1, data.outage_count
    assert_equal HOUR, data.outages.first.seconds
  end

  def test_several_outages_are_ordered_and_counted
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR)
    record(ac: true, at: T0 + 2 * HOUR)
    record(ac: false, at: T0 + 3 * HOUR)
    record(ac: true, at: T0 + 5 * HOUR)

    data = summary(before: T0 + 5 * HOUR)
    assert_equal 2, data.outage_count
    assert_equal [HOUR, 2 * HOUR], data.outages.map(&:seconds)
    assert_equal 2 * HOUR, data.longest_seconds
  end

  def test_the_limit_returns_the_most_recent_outages
    record(ac: true, at: T0)
    3.times do |i|
      record(ac: false, at: T0 + (i + 1) * HOUR)
      record(ac: true, at: T0 + (i + 1.5) * HOUR)
    end
    recent = @report.outages(before: T0 + 6 * HOUR, limit: 2)
    assert_equal 2, recent.length
    # Still chronological. Limiting picks the newest ones off the end; it does not reorder.
    assert_equal [T0 + 2 * HOUR, T0 + 3 * HOUR], recent.map(&:from_ts)
  end

  def test_an_outage_battery_level_is_kept_from_the_moment_it_started
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR, pct: 61)
    record(ac: true, at: T0 + 2 * HOUR)

    assert_equal 61, summary(before: T0 + 2 * HOUR).outages.first.battery_pct_at_start
  end

  # --- coverage, the part that keeps the numbers honest -----------------------------------

  def test_unknown_time_is_counted_separately_and_never_as_uptime
    record(ac: true, at: T0)
    @store.record(Reading.new(ac_online: true, battery_pct: 80, charge_wh: 2.0, has_route: true),
                  at: T0 + 4 * HOUR, gap: 300)  # laptop was off for four hours

    data = summary(before: T0 + 4 * HOUR)
    assert_equal 4 * HOUR, data.unknown_seconds
    assert_equal 0, data.on_ac_seconds
    assert_in_delta 0.0, data.coverage_ratio, 0.001
  end

  def test_coverage_is_observed_over_the_whole_window
    record(ac: true, at: T0)
    record(ac: true, at: T0 + 5 * HOUR)                       # five hours observed, no change
    @store.record(Reading.new(ac_online: true, battery_pct: 80, charge_wh: 2.0, has_route: true),
                  at: T0 + 6 * HOUR, gap: 300)               # laptop off for an hour
    record(ac: true, at: T0 + 7 * HOUR)

    data = summary(before: T0 + 7 * HOUR)
    assert_equal 6 * HOUR, data.observed_seconds
    assert_equal HOUR, data.unknown_seconds
    assert_equal 7 * HOUR, data.window_seconds
    assert_in_delta 6.0 / 7.0, data.coverage_ratio, 0.001
  end

  def test_the_outage_ratio_is_over_observed_time_only
    # One hour on battery inside four observed hours, but a third of the window was
    # unobserved. Dividing by the window would report a calm seventeen percent when the
    # truth about observed time is twenty-five.
    record(ac: true, at: T0)
    record(ac: false, at: T0 + 3 * HOUR)
    record(ac: true, at: T0 + 4 * HOUR)
    @store.record(Reading.new(ac_online: true, battery_pct: 80, charge_wh: 2.0, has_route: true),
                  at: T0 + 6 * HOUR, gap: 300)

    data = summary(before: T0 + 6 * HOUR)
    assert_equal 4 * HOUR, data.observed_seconds
    assert_equal 2 * HOUR, data.unknown_seconds
    assert_equal HOUR, data.outage_seconds
    assert_in_delta 0.25, data.outage_ratio, 0.001
    # The same hour over the whole window, which is the number a naive report would print.
    assert_in_delta 1.0 / 6.0, data.outage_seconds / data.window_seconds, 0.001
  end

  def test_an_unreadable_machine_is_unknown_not_an_outage
    # No adapter could be read. That is not proof of an outage and must not become one.
    record(ac: nil, at: T0)
    record(ac: nil, at: T0 + 2 * HOUR)

    data = summary(before: T0 + 2 * HOUR)
    assert_equal 0, data.outage_count
    assert_equal 2 * HOUR, data.unknown_seconds
  end

  # --- json, for whatever asks the tool rather than reading it ---------------------------

  def test_json_carries_the_coverage_alongside_the_totals
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR)
    record(ac: true, at: T0 + 2 * HOUR)

    json = @report.as_json(before: T0 + 2 * HOUR)
    assert_equal 2 * HOUR, json[:window][:seconds]
    assert_equal 1.0, json[:window][:coverage]
    assert_equal 1, json[:totals][:outage_count]
    assert_equal HOUR, json[:totals][:outage_seconds]
    assert_equal '2025-10-09T09:53:20Z', json[:outages].first[:from]
    assert_equal '2025-10-09T10:53:20Z', json[:outages].first[:to]
  end

  def test_json_marks_an_outage_still_in_progress
    record(ac: true, at: T0)
    record(ac: false, at: T0 + HOUR)

    json = @report.as_json(before: T0 + 3 * HOUR)
    assert_nil json[:outages].first[:to]
    assert_equal 2 * HOUR, json[:outages].first[:seconds]
  end
end
