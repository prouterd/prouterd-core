require "spec_helper"
require "tmpdir"
require "prouterd/daemon/lock"

RSpec.describe Prouterd::Daemon::Lock do
  let(:dir) { Dir.mktmpdir("prouterd-lock") }
  let(:db_path) { File.join(dir, "test.db") }

  after { FileUtils.remove_entry(dir) }

  it "acquires the lock and stamps the holder PID" do
    fd = described_class.acquire(db_path)
    expect(fd).to be_a(File)
    expect(File.read("#{db_path}.lock").to_i).to eq(Process.pid)
  ensure
    fd&.close
  end

  it "refuses a second acquire while the first is held" do
    fd1 = described_class.acquire(db_path)
    expect { described_class.acquire(db_path) }
      .to raise_error(Prouterd::Daemon::LockError, /already holding/)
  ensure
    fd1&.close
  end

  it "lets a fresh acquire succeed once the prior holder closed the FD" do
    fd1 = described_class.acquire(db_path)
    fd1.close
    fd2 = described_class.acquire(db_path)
    expect(fd2).to be_a(File)
  ensure
    fd2&.close
  end

  it "creates the parent directory if missing" do
    nested_db = File.join(dir, "nested", "deep", "test.db")
    fd = described_class.acquire(nested_db)
    expect(File.exist?("#{nested_db}.lock")).to be(true)
  ensure
    fd&.close
  end
end
