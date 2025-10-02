class SlackMessageTag < ApplicationRecord
  validates :channel_id, presence: true
  validates :message_ts, presence: true
  validates :user_id, presence: true
  validates :tags, presence: true

  # タグで検索
  scope :with_tag, ->(tag) { where("? = ANY(tags)", tag) }
  scope :with_any_tags, ->(tags) { where("tags && ARRAY[?]::text[]", tags) }
  scope :recent, -> { order(tagged_at: :desc) }

  # タグを追加（重複を防ぐ）
  def add_tags(new_tags)
    self.tags = (tags + new_tags).uniq
    save
  end
end
