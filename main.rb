# frozen_string_literal: true

require "json"
require "mechanize"
require "optparse"
require "prometheus_exporter"
require "prometheus_exporter/server"

options = {
  address: "127.0.0.1",
  port: 3030,
  amplifi_url: "http://192.168.164.1",
  password: ENV["AMPLIFI_PASSWORD"],
  interval: 15.0,
}
OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby main.rb [options]"

  opts.on("--address ADDR") do |v|
    options[:address] = v
  end
  opts.on("--port PORT") do |v|
    options[:port] = v.to_i
  end
  opts.on("--amplifi URL", "Base URL, e.g. 'http://10.0.0.1'") do |v|
    options[:amplifi_url] = v
  end
  opts.on("--password PASSWORD") do |v|
    options[:password] = v
  end
  opts.on("--interval INTERVAL") do |v|
    options[:interval] = v.to_f
  end
  opts.on("--mock FILE") do |v|
    options[:mock] = v
  end
end.parse!

INTERVAL = options.fetch(:interval)
raise "Invalid interval #{INTERVAL}" if INTERVAL < 5.0
raise "Missing password!" unless options[:password]

trap(:INT) { exit 0 }
trap(:TERM) { exit 0 }

address = options.fetch(:address)
port = options.fetch(:port)
puts "Listen on #{address}:#{port}"
server = PrometheusExporter::Server::WebServer.new \
  bind: address,
  port: port
server.start

all_metrics = [
  device_happiness_score = PrometheusExporter::Metric::Gauge.new("amplifi_device_happiness_score", "Device Happiness Score"),
  device_max_bandwidth = PrometheusExporter::Metric::Gauge.new("amplifi_device_max_bandwidth", "Device Max Bandwidth"),
  device_signal_quality = PrometheusExporter::Metric::Gauge.new("amplifi_device_signal_quality", "Device Signal Quality"),
  device_rx_mcs = PrometheusExporter::Metric::Gauge.new("amplifi_device_rx_mcs", "Device Modulation and Coding Scheme (rx)"),
  device_rx_mhz = PrometheusExporter::Metric::Gauge.new("amplifi_device_rx_mhz", "Device MHz (rx)"),
  device_rx_bitrate = PrometheusExporter::Metric::Gauge.new("amplifi_device_rx_bitrate", "Device rx Bitrate"),
  device_rx_bytes = PrometheusExporter::Metric::Gauge.new("amplifi_device_rx_bytes", "Device Bytes Received"), # KB?
  device_tx_mcs = PrometheusExporter::Metric::Gauge.new("amplifi_device_tx_mcs", "Device Modulation and Coding Scheme (tx)"),
  device_tx_mhz = PrometheusExporter::Metric::Gauge.new("amplifi_device_tx_mhz", "Device MHz (tx)"),
  device_tx_bitrate = PrometheusExporter::Metric::Gauge.new("amplifi_device_tx_bitrate", "Device tx Bitrate"),
  device_tx_bytes = PrometheusExporter::Metric::Gauge.new("amplifi_device_tx_bytes", "Device Bytes Sent"), # KB?

  device_lease_validity = PrometheusExporter::Metric::Gauge.new("amplifi_device_lease_validity", "Time left on DHCP lease"),

  ethernet_link_speed = PrometheusExporter::Metric::Gauge.new("amplifi_ethernet_port_link_speed", "Ethernet Port Link Speed"),
  ethernet_rx_bitrate = PrometheusExporter::Metric::Gauge.new("amplifi_ethernet_port_rx_bitrate", "Ethernet Port Bitrate for Receiving"),
  ethernet_tx_bitrate = PrometheusExporter::Metric::Gauge.new("amplifi_ethernet_port_tx_bitrate", "Ethernet Port Bitrate for Sending"),
]

all_metrics.each do |metric|
  server.collector.register_metric(metric)
end

class AmplifiReader
  def initialize(url:, password:)
    @url = url
    @password = password
    @agent = Mechanize.new
    @agent.follow_meta_refresh = true
    #@agent.log = Logger.new(STDOUT).tap { |l| l.level = Logger::DEBUG }
  end

  def setup
    page = @agent.get(URI.join(@url, "info.php"))
    if page.form
      page.form.password = @password
      page = page.form.submit
    end
    js = page.search("script").find { |s| s["src"].nil? }.text
    js =~ /token='(.*)'/
    @token = $1
  end

  def read
    page = @agent.post(URI.join(@url, "info-async.php"), "do" => "full", "token" => @token)
    JSON.parse(page.body)
  end
end

class TestReader
  def initialize(path)
    @path = path
  end

  def setup
  end

  def read
    JSON.parse(File.read(@path))
  end
end

reader = options[:mock] ?
  TestReader.new(options[:mock]) :
  AmplifiReader.new(url: options.fetch(:amplifi_url), password: options.fetch(:password))

loop do
  puts "Set up #{reader.class}"
  reader.setup

  begin
    loop do
      start = Time.now.to_f

      #puts "Poll #{reader.class}"
      full = reader.read
      p full[0]

      # entry[0] is topology of amplifi mesh.
      # entry[0]: {children, cost, friendly_name, ip, level, mac, platform_name, protocol, role, uptime}
      #   children: {"wifi": {<mac>: {active_band, connected_from, connected_to, connections_from, connections_to, cost, first_connected, friendly_name, ip, last_connected, level, mac, master_peer, platform_modification, platform_name, protocol, role, rssi_min, uptime}

      # entry[1] is wifi device stats per access point.
      # entry[1]: {<band>: {"User network"|"Internal network": {<mac>: {Address, Description, HappinessScore, Inactive, MaxBandwidth, MaxSpatialStreams, Mode, RxBitrate, RxBytes{,_15sec,30sec,5sec,60sec}, RxMcs, RxMhz, SignalQuality, Tx...}}}}
      #  <band> is "2.5 GHz" or "5 GHz"
      full[1].each do |ap_mac, bands|
        bands.each do |band, networks|
          networks.each do |network_type, devices|
            devices.each do |dev_mac, dev_info|
              tags = {
                ip_address: dev_info.fetch("Address", "unknown"),
                mac_address: dev_mac,
                access_point: ap_mac,
                band: band,
                network_type: network_type,
              }
              device_happiness_score.observe(dev_info.fetch("HappinessScore"), tags)
              device_max_bandwidth.observe(dev_info.fetch("MaxBandwidth", nil), tags)
              device_signal_quality.observe(dev_info.fetch("SignalQuality"), tags)
              device_rx_mcs.observe(dev_info.fetch("RxMcs"), tags)
              device_rx_mhz.observe(dev_info.fetch("RxMhz"), tags)
              device_rx_bitrate.observe(dev_info.fetch("RxBitrate"), tags)
              device_rx_bytes.observe(dev_info.fetch("RxBytes"), tags)
              device_tx_mcs.observe(dev_info.fetch("TxMcs"), tags)
              device_tx_mhz.observe(dev_info.fetch("TxMhz"), tags)
              device_tx_bitrate.observe(dev_info.fetch("TxBitrate"), tags)
              device_tx_bytes.observe(dev_info.fetch("TxBytes"), tags)
            end
          end
        end
      end

      # entry[2] is a list of connected devices.
      # entry[2]: {connection: "ethernet"|"wireless", description, host_name, icon_id, ip, lease_validity, peer, dscp, port}
      #  port is only for ethernet
      #  dscp is QoS. possible values include 40, 56 see https://erg.abdn.ac.uk/users/gorry/course/inet-pages/dscp.html
      device_lease_validity.reset!
      full[2].each do |dev_mac, dev_info|
        tags = {
          connection: dev_info.fetch("connection"),
          mac_address: dev_mac,
          ip_address: dev_info.fetch("ip"),
        }
        device_lease_validity.observe(dev_info.fetch("lease_validity", -1), tags)
      end

      # entry[3] is wired devices and which port they're connected to.
      # entry[3]: {<mac>: N}

      # entry[4] is wired interface summaries.
      # entry[4]: {"eth-{0,1,2,3,4}": {link: true|false, link_speed: 100|1000, rx_bitrate, tx_bitrate}}
      #  ping -f got rx/tx to go up to ~1500
      full[4].each do |ap_mac, ports|
        ports.each do |port, port_info|
          tags = {
            access_point: ap_mac,
            ethernet_port: port,
          }
          ethernet_link_speed.observe(port_info.fetch("link_speed"), tags)
          ethernet_rx_bitrate.observe(port_info.fetch("rx_bitrate"), tags)
          ethernet_tx_bitrate.observe(port_info.fetch("tx_bitrate"), tags)
        end
      end

      # entry[5] is discovery.
      # entry[5]: {device, bonjour?}
      #  device: {id, host_name, model_name, name}
      #   model_name: "Ethernet" | "Wireless" | "Sonos One" | "Chromecast" | "Printer"
      #  bonjour: {ip, services}
      #   services: array of string like "_adisk._tcp.local"

      elapsed = Time.now.to_f - start.to_f
      sleep(INTERVAL - elapsed)
    end
  rescue JSON::ParserError => e
    puts "#{e.class}: #{e}"
    puts "starting over in one minute"
    sleep 60
  end
end
