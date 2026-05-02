require "json"
require "securerandom"
require "time"

module Prouterd
  module Storage
    module Repositories
      # Persistence for runs, steps, logs, and artifacts.
      #
      # Mutations always go through transactions when they cross tables — a
      # step transitioning to `success` may write a log row, an artifact row,
      # and update the step row, and we never want a partial picture visible
      # to `show run`.
      class Runs
        UID_PREFIX = "run_".freeze

        def initialize(db)
          @db = db
        end

        # ----- runs -----

        def create_run(process_name:, input_event:, process_config_commit_id: nil,
                       interface_name: nil, parent_run_id: nil, replay_of_run_id: nil)
          uid = generate_uid
          created_at = Time.now.utc.iso8601(3)

          @db.execute(
            <<~SQL,
              INSERT INTO runs
                (uid, process_name, process_config_commit_id, interface_name, status,
                 input_event_json, context_json, created_at, parent_run_id, replay_of_run_id)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            SQL
            [uid, process_name, process_config_commit_id, interface_name, "queued",
             JSON.dump(input_event || {}), JSON.dump({}), created_at,
             parent_run_id, replay_of_run_id]
          )
          get_run(@db.last_insert_row_id)
        end

        def update_run(id, **changes)
          fields = changes.keys.map { |k| "#{k} = ?" }.join(", ")
          values = changes.values
          @db.execute("UPDATE runs SET #{fields} WHERE id = ?", values + [id])
          get_run(id)
        end

        def get_run(id)
          row = @db.query_row(
            "SELECT #{run_columns_with_parent} FROM runs r " \
            "LEFT JOIN runs parent ON r.replay_of_run_id = parent.id " \
            "WHERE r.id = ?", [id]
          )
          row && row_to_run(row)
        end

        def get_run_by_uid(uid)
          row = @db.query_row(
            "SELECT #{run_columns_with_parent} FROM runs r " \
            "LEFT JOIN runs parent ON r.replay_of_run_id = parent.id " \
            "WHERE r.uid = ?", [uid]
          )
          row && row_to_run(row)
        end

        def list_runs(limit: 50, offset: 0, process_name: nil, status: nil)
          conditions = []
          params = []
          if process_name
            conditions << "r.process_name = ?"
            params << process_name
          end
          if status
            conditions << "r.status = ?"
            params << status
          end
          where = conditions.empty? ? "" : "WHERE #{conditions.join(' AND ')}"
          rows = @db.execute(
            "SELECT #{run_columns_with_parent} FROM runs r " \
            "LEFT JOIN runs parent ON r.replay_of_run_id = parent.id " \
            "#{where} ORDER BY r.id DESC LIMIT ? OFFSET ?",
            params + [limit, offset]
          )
          rows.map { |r| row_to_run(r) }
        end

        # ----- steps -----

        def create_step(run_id:, block_name:, attempt: 1, image: nil)
          created_at = Time.now.utc.iso8601(3)
          @db.execute(
            <<~SQL,
              INSERT INTO run_steps
                (run_id, block_name, status, attempt, image, created_at)
              VALUES (?, ?, ?, ?, ?, ?)
            SQL
            [run_id, block_name, "pending", attempt, image, created_at]
          )
          get_step(@db.last_insert_row_id)
        end

        def update_step(id, **changes)
          fields = changes.keys.map { |k| "#{k} = ?" }.join(", ")
          values = changes.values
          @db.execute("UPDATE run_steps SET #{fields} WHERE id = ?", values + [id])
          get_step(id)
        end

        def get_step(id)
          row = @db.query_row("SELECT #{step_columns} FROM run_steps WHERE id = ?", [id])
          row && row_to_step(row)
        end

        def list_steps(run_id)
          rows = @db.execute(
            "SELECT #{step_columns} FROM run_steps WHERE run_id = ? ORDER BY id ASC",
            [run_id]
          )
          rows.map { |r| row_to_step(r) }
        end

        # ----- logs -----

        def append_log(run_id:, step_id: nil, stream:, content:)
          return if content.nil? || content.empty?

          created_at = Time.now.utc.iso8601(3)
          @db.execute(
            "INSERT INTO run_logs (run_id, step_id, stream, content, created_at) VALUES (?, ?, ?, ?, ?)",
            [run_id, step_id, stream, content, created_at]
          )
        end

        def list_logs(run_id, step_id: nil)
          if step_id
            rows = @db.execute(
              "SELECT id, run_id, step_id, stream, content, created_at FROM run_logs WHERE run_id = ? AND step_id = ? ORDER BY id ASC",
              [run_id, step_id]
            )
          else
            rows = @db.execute(
              "SELECT id, run_id, step_id, stream, content, created_at FROM run_logs WHERE run_id = ? ORDER BY id ASC",
              [run_id]
            )
          end
          rows.map do |r|
            LogEntry.new(
              id: r[0], run_id: r[1], step_id: r[2], stream: r[3], content: r[4], created_at: r[5]
            )
          end
        end

        # ----- artifacts -----

        def add_artifact(run_id:, step_id:, block_name:, name:, path:, size_bytes:,
                         content_type: nil, checksum: nil)
          created_at = Time.now.utc.iso8601(3)
          @db.execute(
            <<~SQL,
              INSERT INTO artifacts
                (run_id, step_id, block_name, name, path, content_type, size_bytes, checksum, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            SQL
            [run_id, step_id, block_name, name, path, content_type, size_bytes, checksum, created_at]
          )
        end

        def get_artifact(id)
          row = @db.query_row(
            "SELECT id, run_id, step_id, block_name, name, path, content_type, size_bytes, checksum, created_at FROM artifacts WHERE id = ?",
            [id.to_i]
          )
          return nil unless row

          Artifact.new(
            id: row[0], run_id: row[1], step_id: row[2], block_name: row[3], name: row[4],
            path: row[5], content_type: row[6], size_bytes: row[7], checksum: row[8], created_at: row[9]
          )
        end

        def list_artifacts(run_id, step_id: nil)
          if step_id
            rows = @db.execute(
              "SELECT id, run_id, step_id, block_name, name, path, content_type, size_bytes, checksum, created_at FROM artifacts WHERE run_id = ? AND step_id = ? ORDER BY id ASC",
              [run_id, step_id]
            )
          else
            rows = @db.execute(
              "SELECT id, run_id, step_id, block_name, name, path, content_type, size_bytes, checksum, created_at FROM artifacts WHERE run_id = ? ORDER BY id ASC",
              [run_id]
            )
          end
          rows.map do |r|
            Artifact.new(
              id: r[0], run_id: r[1], step_id: r[2], block_name: r[3], name: r[4],
              path: r[5], content_type: r[6], size_bytes: r[7], checksum: r[8], created_at: r[9]
            )
          end
        end

        private

        def generate_uid
          # 8 hex chars are enough for human display; collisions are checked
          # via UNIQUE constraint and we retry on the (extremely rare) clash.
          5.times do
            candidate = "#{UID_PREFIX}#{SecureRandom.hex(4)}"
            return candidate unless @db.query_row("SELECT 1 FROM runs WHERE uid = ?", [candidate])
          end
          raise StorageError, "could not allocate unique run uid"
        end

        def run_columns
          "id, uid, process_name, process_config_commit_id, interface_name, status, " \
            "input_event_json, context_json, error_summary, started_at, finished_at, " \
            "created_at, parent_run_id, replay_of_run_id"
        end

        # Same fields as run_columns, prefixed with `r.` and tail-appended
        # with parent.uid (NULL when the run has no replay_of_run_id, courtesy
        # of LEFT JOIN). Callers issue this list against `runs r LEFT JOIN
        # runs parent ON r.replay_of_run_id = parent.id`.
        def run_columns_with_parent
          "r.id, r.uid, r.process_name, r.process_config_commit_id, r.interface_name, r.status, " \
            "r.input_event_json, r.context_json, r.error_summary, r.started_at, r.finished_at, " \
            "r.created_at, r.parent_run_id, r.replay_of_run_id, parent.uid AS replay_of_uid"
        end

        def step_columns
          "id, run_id, block_name, status, attempt, image, input_json, output_json, " \
            "exit_code, error_type, error_message, started_at, finished_at, duration_ms, created_at"
        end

        def row_to_run(r)
          Run.new(
            id: r[0], uid: r[1], process_name: r[2], process_config_commit_id: r[3],
            interface_name: r[4], status: r[5], input_event_json: r[6], context_json: r[7],
            error_summary: r[8], started_at: r[9], finished_at: r[10], created_at: r[11],
            parent_run_id: r[12], replay_of_run_id: r[13],
            replay_of_uid: r[14]  # set by run_columns_with_parent / nil for run_columns
          )
        end

        def row_to_step(r)
          Step.new(
            id: r[0], run_id: r[1], block_name: r[2], status: r[3], attempt: r[4],
            image: r[5], input_json: r[6], output_json: r[7], exit_code: r[8],
            error_type: r[9], error_message: r[10], started_at: r[11], finished_at: r[12],
            duration_ms: r[13], created_at: r[14]
          )
        end
      end
    end
  end
end
