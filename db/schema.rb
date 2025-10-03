# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_10_03_155544) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "slack_message_tags", force: :cascade do |t|
    t.string "channel_id", null: false
    t.string "message_ts", null: false
    t.string "user_id", null: false
    t.text "tags", default: [], array: true
    t.text "message_text"
    t.string "message_link"
    t.datetime "tagged_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_thread_ts"
    t.jsonb "tag_threads", default: {}
    t.index ["channel_id", "message_ts"], name: "index_slack_message_tags_on_channel_id_and_message_ts", unique: true
    t.index ["tagged_at"], name: "index_slack_message_tags_on_tagged_at"
    t.index ["tags"], name: "index_slack_message_tags_on_tags", using: :gin
    t.index ["user_id", "user_thread_ts"], name: "index_slack_message_tags_on_user_id_and_user_thread_ts"
  end
end
