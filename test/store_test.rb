# frozen_string_literal: true

require 'minitest/autorun'
require 'pathname'
require 'tmpdir'
require_relative '../lib/tinaja_power/store'

class StoreTest < Minitest::Test
  T0 = 1_760_000_000.0 # an arbitrary fixed instant, so no test depends on the real clock

  # Deliberately not Sysfs::Reading. The store only ever asks a reading for four fields, so
  # it has no business knowing where readings come from.
  Reading = Data.define(:ac_online, :battery_pct, :charge_wh, :has_route)

  # A gap threshold no test in this file trips by accident. Tests that are not about
  # losing contact pass this explicitly, so that the ones which are stay obvious.
  WATCHING = 1_000_000.0

  def setup
    @dir = Pathname(Dir.mktmpdir('tinaja-power-store'))
    @store = TinajaPower::Store.new(@dir + 'power.db')
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@dir) if @dir.exist?
  end

  def reading(ac: true, pct: 88, wh: 2.5, route: true)
    Reading.new(ac_online: ac, battery_pct: pct, charge_wh: wh, has_route: route)
  end

  def states = @store.intervals.map { |i| i.ac_online }

  # --- the ordinary path ----------------------------------------------------------------

  def test_first_record_opens_an_interval
    assert_equal :recorded, @store.record(reading, at: T0)
    interval = @store.open_interval
    assert_equal T0, interval.from_ts
    assert_nil interval.to_ts
    assert_equal 1, interval.ac_online
    assert_equal 88, interval.battery_pct
  end

  def test_recording_the_same_state_again_changes_nothing
    @store.record(reading, at: T0)
    assert_equal :unchanged, @store.record(reading, at: T0 + 30, gap: WATCHING)
    assert_equal 1, @store.intervals.length
  end

  def test_unplugging_splits_the_interval
    @store.record(reading, at: T0)
    assert_equal :recorded, @store.record(reading(ac: false, pct: 87), at: T0 + 600, gap: WATCHING)
    assert_equal [1, 0], states
    assert_equal T0 + 600, @store.intervals.first.to_ts
  end

  def test_plugging_back_in_splits_it_again
    @store.record(reading(ac: false), at: T0)
    @store.record(reading(ac: true), at: T0 + 300, gap: WATCHING)
    assert_equal [0, 1], states
  end

  def test_there_is_never_more_than_one_open_interval
    @store.record(reading, at: T0)
    20.times { |i| @store.record(reading(ac: i.even?), at: T0 + (i * 10)) }
    assert_equal 1, @store.intervals.count(&:open?)
  end

  # --- the rule that matters -------------------------------------------------------------

  def test_being_away_too_long_writes_unknown_not_an_extension
    # Six hours of the laptop being shut. If that were folded into the previous interval,
    # the history would claim six hours of power we never checked.
    @store.record(reading, at: T0)
    assert_equal :gap, @store.record(reading, at: T0 + 6 * 3600, gap: 300)

    intervals = @store.intervals
    assert_equal [1, nil, 1], intervals.map(&:ac_online)
    assert_equal T0 + 6 * 3600 - T0, intervals[1].seconds(T0 + 6 * 3600)
    assert intervals[1].unknown?
  end

  def test_a_gap_closes_the_previous_interval_at_the_last_sighting
    # Not at the current time: we only know the state up to the moment we last looked.
    @store.record(reading, at: T0)
    @store.record(reading, at: T0 + 10_000, gap: 300)
    assert_equal T0, @store.intervals.first.to_ts
  end

  def test_a_gap_just_under_the_threshold_is_not_a_gap
    @store.record(reading, at: T0)
    assert_equal :unchanged, @store.record(reading, at: T0 + 299, gap: 300)
    assert_equal [1], states
  end

  def test_a_gap_exactly_at_the_threshold_is_not_a_gap
    @store.record(reading, at: T0)
    assert_equal :unchanged, @store.record(reading, at: T0 + 300, gap: 300)
    assert_equal [1], states
  end

  def test_an_unknown_interval_carries_no_invented_context
    @store.record(reading, at: T0)
    @store.record(reading, at: T0 + 10_000, gap: 300)
    unknown = @store.intervals[1]
    assert_nil unknown.battery_pct
    assert_nil unknown.charge_wh
    assert_nil unknown.has_route
  end

  def test_the_state_after_a_gap_still_reflects_the_machine
    @store.record(reading(ac: true), at: T0)
    @store.record(reading(ac: false), at: T0 + 10_000, gap: 300)
    assert_equal [1, nil, 0], states
  end
  def test_no_gap_is_written_for_the_very_first_record
    # Nothing was ever observed before now, so there is no gap to record, only a start.
    assert_equal :recorded, @store.record(reading, at: T0)
    assert_equal [1], states
  end

  def test_a_clock_that_jumps_backwards_is_refused
    @store.record(reading, at: T0)
    assert_raises(TinajaPower::Store::ClockWentBackwards) do
      @store.record(reading, at: T0 - 60)
    end
  end

  # --- an unreadable machine -------------------------------------------------------------

  def test_an_unreadable_adapter_records_unknown
    # No mains supply at all. That is unknown, not "on battery", and it is certainly not
    # an outage.
    @store.record(reading, at: T0)
    assert_equal :recorded, @store.record(reading(ac: nil), at: T0 + 30, gap: WATCHING)
    assert_equal [1, nil], states
  end

  def test_reading_the_same_unreadable_machine_twice_writes_nothing
    @store.record(reading(ac: nil), at: T0)
    assert_equal :unchanged, @store.record(reading(ac: nil), at: T0 + 30, gap: WATCHING)
    assert_equal 1, @store.intervals.length
  end

  # --- network context ------------------------------------------------------------------

  def test_the_network_change_is_recorded_once
    @store.record(reading(route: true), at: T0)
    5.times { @store.record(reading(route: true), at: T0 + 30, gap: WATCHING) }
    assert_equal 1, @store.net_events.length
  end

  def test_the_network_dropping_and_returning_is_both_recorded
    @store.record(reading(route: true), at: T0)
    @store.record(reading(route: false), at: T0 + 60, gap: WATCHING)
    @store.record(reading(route: true), at: T0 + 3600, gap: WATCHING)
    assert_equal [true, false, true], @store.net_events.map(&:has_route)
  end

  def test_a_machine_with_no_route_still_records_it
    @store.record(reading(route: false), at: T0)
    assert_equal [false], @store.net_events.map(&:has_route)
  end

  # --- querying --------------------------------------------------------------------------

  def test_intervals_can_be_windowed
    @store.record(reading(ac: true), at: T0)
    @store.record(reading(ac: false), at: T0 + 3600, gap: WATCHING)
    @store.record(reading(ac: true), at: T0 + 7200, gap: WATCHING)

    assert_equal 3, @store.intervals(since: T0 - 1).length
    assert_equal 2, @store.intervals(before: T0 + 7200).length
    assert_equal 1, @store.intervals(before: T0 + 3600).length
  end

  def test_a_window_returns_intervals_that_overlap_it_not_only_ones_inside_it
    # An outage that began before the window but is still going is part of the window.
    # Reporting nothing here is how a history ends up claiming an outage never happened.
    @store.record(reading(ac: true), at: T0)
    @store.record(reading(ac: false), at: T0 + 3600, gap: WATCHING)
    @store.record(reading(ac: true), at: T0 + 7200, gap: WATCHING)

    overlapping = @store.intervals(since: T0 + 5400)
    # The on-battery interval started at T0 + 3600, before the window opened, and is
    # still inside it. It has to be in the result.
    assert_includes overlapping.map(&:ac_online), 0
    assert_equal [0, 1], overlapping.map(&:ac_online)
  end

  def test_the_open_interval_is_measured_against_now
    @store.record(reading, at: T0)
    assert_equal 900, @store.open_interval.seconds(T0 + 900)
  end

  def test_the_database_survives_being_reopened
    @store.record(reading(ac: true), at: T0)
    @store.record(reading(ac: false), at: T0 + 600, gap: WATCHING)
    @store.close

    reopened = TinajaPower::Store.new(@dir + 'power.db')
    assert_equal [1, 0], reopened.intervals.map(&:ac_online)
    reopened.close
    @store = TinajaPower::Store.new(@dir + 'power.db') # so teardown has something to close
  end
end
