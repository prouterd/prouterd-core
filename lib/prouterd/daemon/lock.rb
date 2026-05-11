# frozen_string_literal: true

require "fileutils"

module Prouterd
  module Daemon
    class LockError < StandardError; end

    # Process-level mutex: refuses to start a second daemon on the same
    # SQLite DB. Two daemons against one DB would fight for jobs and —
    # more dangerously — the second one's `Recovery.sweep` on boot
    # would mark the first daemon's in-flight runs as failed (see
    # `Runtime::Recovery` design notes; single-writer assumption).
    #
    # Lock file lives next to the DB at `<db_path>.lock`. `flock(2)` is
    # held on an open FD; the kernel releases it automatically when the
    # process exits, so a crash leaves no stale state to clean up.
    #
    # Linux/macOS use the same `flock` syscall; on Windows this is a
    # no-op (Ruby returns true unconditionally). The Windows path is
    # not a supported deployment target — the daemon needs `fork`-ish
    # threading semantics anyway — so the missing protection there is
    # acceptable.
    class Lock
      def self.acquire(db_path)
        lock_path = "#{db_path}.lock"
        FileUtils.mkdir_p(File.dirname(lock_path))

        f = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
        unless f.flock(File::LOCK_EX | File::LOCK_NB)
          f.close
          raise LockError,
                "another prouterd is already holding #{lock_path} " \
                "(another daemon is running on this DB, or a previous " \
                "process is still shutting down)"
        end

        # Stamp the holder's PID for ops visibility — `cat <db>.lock`
        # tells you who's holding it. Not used for liveness; flock
        # state is the source of truth.
        f.truncate(0)
        f.write("#{Process.pid}\n")
        f.flush
        f
      end
    end
  end
end
