# frozen_string_literal: true

require 'pathname'

module LotoPower
  # Reads the machine's power and network state.
  #
  # The sysfs and procfs roots are constructor arguments rather than constants so a test
  # can point the whole thing at a fixture tree. Nothing here writes, and nothing here
  # raises: a file the kernel does not expose comes back as nil, and nil is a real answer
  # here, not a failure. "The adapter is gone" and "we could not read the adapter" both
  # mean we do not know whether the office has power.
  #
  # Reads are memoised, so one instance is one consistent snapshot. Take a new reading by
  # building a new Sysfs; do not reuse one across a state change and expect it to notice.
  class Sysfs
    # What one look at the machine looks like. Any field may be nil, meaning unknown.
    Reading = Data.define(:ac_online, :battery_pct, :charge_wh, :has_route, :iface)

    DEFAULT_SYSFS = Pathname('/sys')
    DEFAULT_PROCFS = Pathname('/proc')

    # /proc/net/route is a hex dump. The default route is the row with a zero destination.
    DEFAULT_DESTINATION = '00000000'

    def initialize(sysfs: DEFAULT_SYSFS, procfs: DEFAULT_PROCFS)
      @power_supply = sysfs + 'class/power_supply'
      @route = procfs + 'net/route'
    end

    # One look at everything, so a caller gets a consistent picture from a single pass.
    def reading
      route_iface = iface
      Reading.new(
        ac_online: ac_online,
        battery_pct: battery_pct,
        charge_wh: charge_wh,
        has_route: !route_iface.nil?,
        iface: route_iface
      )
    end

    # True on AC, false on battery, nil when no mains supply can be read.
    def ac_online
      mains = supplies('Mains')
      return nil if mains.empty?

      # map then compact, not filter_map: filter_map drops false along with nil, and
      # "unplugged" is exactly the answer we are looking for.
      states = mains.map { |dir| bool(dir + 'online') }.compact
      return nil if states.empty?

      states.any?
    end

    # Charge percentage of the first present cell, or nil if there is no battery at all.
    def battery_pct
      cell = cells.first
      cell && integer(cell + 'capacity')
    end

    # Charge currently stored, in watt-hours. /sys reports micro-watt-hours.
    def charge_wh
      cell = cells.first
      microwatts = cell && integer(cell + 'charge_now')
      microwatts && (microwatts / 1_000_000.0).round(3)
    end

    # Interface carrying the default route, or nil when there is no route out.
    def iface
      route_fields&.fetch(0, nil)
    end

    # Whether there is a route out, which is the only thing a public lookup would need.
    def has_route
      !iface.nil?
    end

    private

    def route_fields
      return @route_fields if defined?(@route_fields)

      @route_fields = begin
        @route.readlines.drop(1).map(&:split).find do |fields|
          fields.length >= 3 && fields[1] == DEFAULT_DESTINATION
        end
      rescue SystemCallError, IOError
        nil
      end
    end

    # Present battery cells, ignoring placeholders that report present = 0.
    def cells
      @cells ||= supplies('Battery').select { |dir| text(dir + 'present') == '1' }
    end

    # Every power supply of a type. An unreadable directory yields none, which the callers
    # read as unknown rather than as an empty machine.
    def supplies(kind)
      @supplies ||= {}
      @supplies[kind] ||= begin
        @power_supply.children.select { |dir| text(dir + 'type') == kind }
      rescue SystemCallError, IOError
        []
      end
    end

    def text(path)
      path.read.strip
    rescue SystemCallError, IOError
      nil
    end

    def integer(path)
      text(path)&.to_i
    end

    # /sys booleans are "0" or "1". Anything else is not a boolean we understand.
    def bool(path)
      case text(path)
      when '1' then true
      when '0' then false
      end
    end
  end
end
