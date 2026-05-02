require "spec_helper"

RSpec.describe Prouterd::Runner::DockerRunner, "demultiplex_logs cap" do
  let(:runner) { described_class.new }

  # Build a Docker-API multiplex log frame: 8-byte header (stream + size)
  # then payload. stream==1 is stdout, stream==2 is stderr.
  def frame(stream, payload)
    bytes = payload.bytesize
    [stream, 0, bytes].pack("CC*N").b + payload.b
  end

  # The actual header: 1 byte stream | 3 bytes pad zero | 4 bytes size BE.
  def real_frame(stream, payload)
    [stream, 0, 0, 0, payload.bytesize].pack("C C C C N") + payload.b
  end

  it "caps stdout at the configured byte budget and notes truncation" do
    big = "x" * 200_000
    raw = real_frame(1, big)
    out, err = runner.send(:demultiplex_logs, raw, cap: 1_000)
    expect(out.bytesize).to be <= 1_100  # 1KB cap + small truncation marker
    expect(out).to include("truncated")
    expect(err).to eq("")
  end

  it "leaves small streams alone" do
    raw = real_frame(1, "hi") + real_frame(2, "warn")
    out, err = runner.send(:demultiplex_logs, raw, cap: 1_000)
    expect(out).to eq("hi")
    expect(err).to eq("warn")
  end

  it "returns ['', ''] on empty input" do
    expect(runner.send(:demultiplex_logs, nil, cap: 1000)).to eq(["", ""])
    expect(runner.send(:demultiplex_logs, "", cap: 1000)).to eq(["", ""])
  end
end
