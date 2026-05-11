# frozen_string_literal: true

require "digest"
require "time"

module Prouterd
  module Storage
    module Repositories
      # Persistence for config commits and pointers ("running", "startup").
      #
      # All writes go through `transaction` so a save_commit + set_pointer
      # pair (used during a shell `commit`) is atomic — there's never a state
      # where running points at a commit that doesn't exist.
      class Configs
        def initialize(db)
          @db = db
        end

        # ----- commits -----

        def save_commit(rendered_config:, compiled_config_json: nil, author: nil, message: nil)
          checksum = Digest::SHA256.hexdigest(rendered_config)
          created_at = Time.now.utc.iso8601(3)

          @db.transaction do
            @db.execute(
              <<~SQL,
                INSERT INTO config_commits
                  (checksum, author, message, rendered_config, compiled_config_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
              SQL
              [checksum, author, message, rendered_config, compiled_config_json, created_at]
            )
            id = @db.last_insert_row_id
            Commit.new(
              id: id,
              checksum: checksum,
              author: author,
              message: message,
              rendered_config: rendered_config,
              compiled_config_json: compiled_config_json,
              created_at: created_at
            )
          end
        end

        def get_commit(id)
          row = @db.query_row(
            <<~SQL,
              SELECT id, checksum, author, message, rendered_config, compiled_config_json, created_at
              FROM config_commits
              WHERE id = ?
            SQL
            [id]
          )
          row && row_to_commit(row)
        end

        def latest_commit
          row = @db.query_row(<<~SQL)
            SELECT id, checksum, author, message, rendered_config, compiled_config_json, created_at
            FROM config_commits
            ORDER BY id DESC
            LIMIT 1
          SQL
          row && row_to_commit(row)
        end

        # Returns commits newest first.
        def list_commits(limit: 50, offset: 0)
          rows = @db.execute(
            <<~SQL,
              SELECT id, checksum, author, message, rendered_config, compiled_config_json, created_at
              FROM config_commits
              ORDER BY id DESC
              LIMIT ? OFFSET ?
            SQL
            [limit, offset]
          )
          rows.map { |r| row_to_commit(r) }
        end

        def count_commits
          row = @db.query_row("SELECT COUNT(*) FROM config_commits")
          row.first
        end

        # ----- pointers -----

        def get_pointer(name)
          row = @db.query_row(
            "SELECT name, commit_id, updated_at FROM config_pointers WHERE name = ?",
            [name]
          )
          row && Pointer.new(name: row[0], commit_id: row[1], updated_at: row[2])
        end

        def set_pointer(name, commit_id)
          updated_at = Time.now.utc.iso8601(3)
          @db.transaction do
            existing = @db.query_row(
              "SELECT 1 FROM config_pointers WHERE name = ?", [name]
            )
            if existing
              @db.execute(
                "UPDATE config_pointers SET commit_id = ?, updated_at = ? WHERE name = ?",
                [commit_id, updated_at, name]
              )
            else
              @db.execute(
                "INSERT INTO config_pointers (name, commit_id, updated_at) VALUES (?, ?, ?)",
                [name, commit_id, updated_at]
              )
            end
          end
          Pointer.new(name: name, commit_id: commit_id, updated_at: updated_at)
        end

        private

        def row_to_commit(row)
          Commit.new(
            id: row[0],
            checksum: row[1],
            author: row[2],
            message: row[3],
            rendered_config: row[4],
            compiled_config_json: row[5],
            created_at: row[6]
          )
        end
      end
    end
  end
end
