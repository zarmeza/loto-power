# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'tmpdir'

module TinajaPower
  # Builds a throwaway /sys and /proc on disk so the readers can be tested against real
  # files rather than against stubs. Reading the filesystem is the whole job, so mocking
  # the filesystem would test the mock.
  module FakeMachine
    # The three supplies this laptop actually has, plus enough knobs to describe the
    # states that matter. Anything left nil is simply not written, which is how a kernel
    # that does not expose a file behaves.
    DEFAULTS = {
      ac_online: '1',
      battery_status: 'Full',
      battery_capacity: '88',
      battery_present: '1',
      battery_charge_now: '2_516_000',
      route: true,
      iface: 'wlp3s0',
      gateway: '0164A8C0'
    }.freeze

    # Minitest's setup and teardown are instance hooks, not class-level macros, so a test
    # class wires these in itself:
    #
    #   def setup   = TinajaPower::FakeMachine.fresh_root
    #   def teardown = TinajaPower::FakeMachine.discard(@root)

    def self.fresh_root
      Pathname(Dir.mktmpdir('tinaja-power'))
    end

    def self.discard(root)
      FileUtils.remove_entry(root) if root&.exist?
    end

    # Writes a machine into the test's tmpdir and hands back a Sysfs pointed at it.
    def fake_machine(**overrides)
      options = DEFAULTS.merge(overrides)
      write_power_supply(options)
      write_route(options)
      Sysfs.new(sysfs: @root + 'sys', procfs: @root + 'proc')
    end

    # Writes a machine with no mains adapter at all, which is unknown, not "on battery".
    def machine_without_ac(**overrides)
      options = DEFAULTS.merge(overrides).merge(ac_online: nil)
      write_power_supply(options)
      write_route(options)
      Sysfs.new(sysfs: @root + 'sys', procfs: @root + 'proc')
    end

    private

    def write_power_supply(options)
      base = @root + 'sys/class/power_supply'
      unless options[:ac_online].nil?
        write_supply(base + 'ADP1', 'Mains', online: options[:ac_online])
      end
      write_supply(
        base + 'BAT0',
        'Battery',
        status: options[:battery_status],
        capacity: options[:battery_capacity],
        present: options[:battery_present],
        charge_now: options[:battery_charge_now]
      )
    end

    def write_supply(dir, type, **files)
      dir.mkpath
      (dir + 'type').write("#{type}\n")
      files.each { |name, value| (dir + name.to_s).write("#{value}\n") unless value.nil? }
    end

    def write_route(options)
      path = @root + 'proc/net/route'
      path.dirname.mkpath
      rows = ["Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT"]
      if options[:route]
        rows << "#{options[:iface]}\t00000000\t#{options[:gateway]}\t0003\t0\t0\t600\t00000000\t0\t0\t0"
      end
      rows << "docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0"
      path.write("#{rows.join("\n")}\n")
    end
  end
end
