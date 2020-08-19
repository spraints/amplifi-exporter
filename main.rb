require "json"
require "mechanize"
require "prometheus_exporter"
require "prometheus_exporter/server"

trap(:INT) { exit 0 }
trap(:TERM) { exit 0 }

metrics_addr = "127.0.0.1"
metrics_port = 3030
amplifi_url = "http://192.168.164.1/"
password = ENV.fetch("AMPLIFI_PASSWORD")

server = PrometheusExporter::Server::WebServer.new \
  bind: "127.0.0.1",
  port: 3030
server.start

sample_gauge = PrometheusExporter::Metric::Gauge.new("sample_count", "sample count")

server.collector.register_metric(sample_gauge)

require "pp"
require "byebug"
agent = Mechanize.new
agent.follow_meta_refresh = true
page = agent.get(amplifi_url + "info.php")
if page.form
  page.form.password = password
  page = page.form.submit
end
js = page.search("script").find { |s| s["src"].nil? }.text
js =~ /token='(.*)'/
token = $1

page = agent.post(amplifi_url + "info-async.php", "do" => "devicelist", "token" => token)
File.write "devicelist.json", page.body
devices = JSON.parse(page.body) # generic info about devices
# {
#   "dev_ids => { # all possible devices?
#     "1" => # ordinal
#      {"name" => "...",
#       vendor_id, # 1 - 854
#       os_name_id, # 1 - 82
#       os_class_id, # 1 - 79
#       dev_type_id, # 1 - 203
#       family_id, # 1 - 134
#       fb_id, # nil, or a number up to 51762
#       tm_id, # nil, or a number up to 41219
#       ctag_id # nil, or 101 - 105
#      },
#    ...
#   },
#   "dev_type_ids" => ...
#   "family_ids" => ...
#   "os_class_ids" => ...
#   "os_name_ids" => ...
#   "vendor_ids" => ...
#   "ctag_ids" => ...
# }

page = agent.post(amplifi_url + "info-async.php", "do" => "full", "token" => token)
File.write "full.json", page.body
full = JSON.parse(page.body) # array of hash (mac => entry[i])
# entry[0] is topology of amplifi mesh.
# entry[0]: {children, cost, friendly_name, ip, level, mac, platform_name, protocol, role, uptime}
#   children: {"wifi": {<mac>: {active_band, connected_from, connected_to, connections_from, connections_to, cost, first_connected, friendly_name, ip, last_connected, level, mac, master_peer, platform_modification, platform_name, protocol, role, rssi_min, uptime}
#
# entry[1] is wifi device stats per access point.
# entry[1]: {<band>: {"User network"|"Internal network": {<mac>: {Address, Description, HappinessScore, Inactive, MaxBandwidth, MaxSpatialStreams, Mode, RxBitrate, RxBytes{,_15sec,30sec,5sec,60sec}, RxMcs, RxMhz, SignalQuality, Tx...}}}}
#
# entry[2] is a list of connected devices.
# entry[2]: {connection: "ethernet"|"wireless", description, host_name, icon_id, ip, lease_validity, peer, dscp, port}
#  port is only for ethernet
#  dscp is QoS. possible values include 40, 56 see https://erg.abdn.ac.uk/users/gorry/course/inet-pages/dscp.html
#
# entry[3] is wired devices and which port they're connected to.
# entry[3]: {<mac>: N}
#
# entry[4] is wired interface summaries.
# entry[4]: {"eth-{0,1,2,3,4}": {link: true|false, link_speed: 100|1000, rx_bitrate, tx_bitrate}}
#  ping -f got rx/tx to go up to ~1500
#
# entry[5] is discovery.
# entry[5]: {device, bonjour?}
#  device: {id, host_name, model_name, name}
#   model_name: "Ethernet" | "Wireless" | "Sonos One" | "Chromecast" | "Printer"
#  bonjour: {ip, services}
#   services: array of string like "_adisk._tcp.local"

byebug
exit 0

#n = 0
#loop do
#  n = (n + 1) % 20
#  sample_gauge.observe(n)
#  sleep(1.0)
#end
