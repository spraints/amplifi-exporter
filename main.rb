require "prometheus_exporter"
require "prometheus_exporter/server"

trap(:INT) { exit 0 }
trap(:TERM) { exit 0 }

server = PrometheusExporter::Server::WebServer.new \
  bind: "127.0.0.1",
  port: 3030
server.start

sample_gauge = PrometheusExporter::Metric::Gauge.new("sample_count", "sample count")

server.collector.register_metric(sample_gauge)

n = 0
loop do
  n = (n + 1) % 20
  sample_gauge.observe(n)
  sleep(1.0)
end
