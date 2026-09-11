#!/usr/bin/env ruby
# Container-side HTTP driver for benchmarks/benchmark_saturation.py.
#
# It exists for one reason: on Docker Desktop every request that leaves the Mac
# for a published port crosses the VM's port forwarder, and that forwarding
# costs CPU and latency that belong to the test rig rather than to Judge0. The
# question the sweep has to answer is why throughput stops scaling, so the load
# generator runs on the compose network instead, where the only thing between
# the driver and the API is the bridge.
#
# It is deliberately dumb: the workload arrives as a JSON array of finished
# request bodies, so the definition of "cold compile" and "cache hit" stays in
# one place -- the Python harness -- and this file never needs to know what a
# submission is. One JSON object per request goes to stdout when the level is
# done, plus a final {"_meta": ...} line carrying the driver's own CPU cost, so
# the report can show what the measuring equipment ate.
require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

opts = {
  url: "http://server:2358",
  workload: nil,
  concurrency: 1,
  path: "/submissions?wait=true&base64_encoded=false",
}

OptionParser.new do |parser|
  parser.on("--url URL") { |value| opts[:url] = value }
  parser.on("--workload FILE") { |value| opts[:workload] = value }
  parser.on("--concurrency N", Integer) { |value| opts[:concurrency] = value }
end.parse!

abort "loadgen: --workload is required" unless opts[:workload]

def cpu_usec
  File.read("/sys/fs/cgroup/cpu.stat")[/usage_usec (\d+)/, 1].to_i
end

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

payloads = JSON.parse(File.read(opts[:workload]))
uri = URI(opts[:url])
queue = Queue.new
payloads.each_with_index { |payload, index| queue << [index, payload] }
results = Queue.new

cpu_before = cpu_usec
started_at = clock

threads = opts[:concurrency].times.map do
  Thread.new do
    http = nil
    begin
      http = Net::HTTP.start(uri.host, uri.port, open_timeout: 30, read_timeout: 600)
      loop do
        item = begin
          queue.pop(true)
        rescue ThreadError
          break
        end
        index, payload = item
        request_started = clock
        row = { "i" => index }
        begin
          request = Net::HTTP::Post.new(opts[:path], "Content-Type" => "application/json")
          request.body = JSON.generate(payload)
          response = http.request(request)
          row["code"] = response.code.to_i
          body = begin
            JSON.parse(response.body)
          rescue StandardError
            nil
          end
          if body.is_a?(Hash)
            row["token"] = body["token"]
            row["status"] = body.dig("status", "description")
            row["time"] = body["time"]
            row["memory"] = body["memory"]
            row["error_field"] = body["error"]
          end
        rescue StandardError => error
          row["code"] = 0
          row["error"] = "#{error.class}: #{error.message}"
        end
        row["ms"] = ((clock - request_started) * 1000).round(2)
        row["t_ms"] = ((request_started - started_at) * 1000).round(2)
        results << row
      end
    rescue StandardError => error
      results << { "i" => -1, "code" => 0, "error" => "driver thread died: #{error.class}: #{error.message}",
                   "ms" => 0.0, "t_ms" => 0.0 }
    ensure
      begin
        http&.finish
      rescue StandardError
        nil
      end
    end
  end
end

threads.each(&:join)
wall_s = clock - started_at

rows = []
rows << results.pop until results.empty?
rows.sort_by! { |row| row["i"] }
rows.each { |row| puts JSON.generate(row) }
puts JSON.generate(
  "_meta" => {
    "wall_s" => wall_s.round(3),
    "requests" => payloads.size,
    "concurrency" => opts[:concurrency],
    "driver_cpu_usec" => cpu_usec - cpu_before,
    "finished" => Time.now.utc.iso8601,
  },
)
