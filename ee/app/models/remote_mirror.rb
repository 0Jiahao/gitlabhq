class RemoteMirror < ActiveRecord::Base
  include AfterCommitQueue

  PROTECTED_BACKOFF_DELAY   = 1.minute
  UNPROTECTED_BACKOFF_DELAY = 5.minutes

  attr_encrypted :credentials,
                 key: Gitlab::Application.secrets.db_key_base,
                 marshal: true,
                 encode: true,
                 mode: :per_attribute_iv_and_salt,
                 insecure_mode: true,
                 algorithm: 'aes-256-cbc'

  default_value_for :only_protected_branches, true

  belongs_to :project, inverse_of: :remote_mirrors

  validates :url, presence: true, url: { protocols: %w(ssh git http https), allow_blank: true }

  validate  :url_availability, if: -> (mirror) { mirror.url_changed? || mirror.enabled? }
  validates :url, addressable_url: true, if: :url_changed?

  before_save :refresh_remote, if: :mirror_url_changed?

  after_save :set_override_remote_mirror_available, unless: -> { Gitlab::CurrentSettings.current_application_settings.mirror_available }
  after_update :reset_fields, if: :mirror_url_changed?
  after_destroy :remove_remote

  scope :enabled, -> { where(enabled: true) }
  scope :started, -> { with_update_status(:started) }
  scope :stuck,   -> { started.where('last_update_at < ? OR (last_update_at IS NULL AND updated_at < ?)', 1.day.ago, 1.day.ago) }

  state_machine :update_status, initial: :none do
    event :update_start do
      transition [:none, :finished, :failed] => :started
    end

    event :update_finish do
      transition started: :finished
    end

    event :update_fail do
      transition started: :failed
    end

    state :started
    state :finished
    state :failed

    after_transition any => :started do |remote_mirror, _|
      Gitlab::Metrics.add_event(:remote_mirrors_running, path: remote_mirror.project.full_path)

      remote_mirror.update(last_update_started_at: Time.now)
    end

    after_transition started: :finished do |remote_mirror, _|
      Gitlab::Metrics.add_event(:remote_mirrors_finished, path: remote_mirror.project.full_path)

      timestamp = Time.now
      remote_mirror.update_attributes!(
        last_update_at: timestamp, last_successful_update_at: timestamp, last_error: nil
      )
    end

    after_transition started: :failed do |remote_mirror, _|
      Gitlab::Metrics.add_event(:remote_mirrors_failed, path: remote_mirror.project.full_path)

      remote_mirror.update(last_update_at: Time.now)
    end
  end

  def remote_name
    name = read_attribute(:remote_name)

    return name if name
    return unless id

    "remote_mirror_#{id}"
  end

  def update_failed?
    update_status == 'failed'
  end

  def update_in_progress?
    update_status == 'started'
  end

  def update_repository(options)
    raw.update(options)
  end

  def sync
    return unless enabled?
    return if Gitlab::Geo.secondary?

    if recently_scheduled?
      RepositoryUpdateRemoteMirrorWorker.perform_in(backoff_delay, self.id, Time.now)
    else
      RepositoryUpdateRemoteMirrorWorker.perform_async(self.id, Time.now)
    end
  end

  def enabled
    return false unless project && super
    return false unless project.remote_mirror_available?
    return false unless project.repository_exists?
    return false if project.pending_delete?

    # Sync is only enabled when the license permits it
    project.feature_available?(:repository_mirrors)
  end
  alias_method :enabled?, :enabled

  def updated_since?(timestamp)
    last_update_started_at && last_update_started_at > timestamp && !update_failed?
  end

  def mark_for_delete_if_blank_url
    mark_for_destruction if url.blank?
  end

  def mark_as_failed(error_message)
    update_fail
    update_column(:last_error, Gitlab::UrlSanitizer.sanitize(error_message))
  end

  def url=(value)
    super(value) && return unless Gitlab::UrlSanitizer.valid?(value)

    mirror_url = Gitlab::UrlSanitizer.new(value)
    self.credentials = mirror_url.credentials

    super(mirror_url.sanitized_url)
  end

  def url
    if super
      Gitlab::UrlSanitizer.new(super, credentials: credentials).full_url
    end
  rescue
    super
  end

  def safe_url
    return if url.nil?

    result = URI.parse(url)
    result.password = '*****' if result.password
    result.user = '*****' if result.user && result.user != "git" # tokens or other data may be saved as user
    result.to_s
  end

  private

  def raw
    @raw ||= Gitlab::Git::RemoteMirror.new(project.repository.raw, remote_name)
  end

  def recently_scheduled?
    return false unless self.last_update_started_at

    self.last_update_started_at >= Time.now - backoff_delay
  end

  def backoff_delay
    if self.only_protected_branches
      PROTECTED_BACKOFF_DELAY
    else
      UNPROTECTED_BACKOFF_DELAY
    end
  end

  def url_availability
    return unless project

    if project.import_url == url && project.mirror?
      errors.add(:url, 'is already in use')
    end
  end

  def reset_fields
    update_columns(
      last_error: nil,
      last_update_at: nil,
      last_successful_update_at: nil,
      update_status: 'finished'
    )
  end

  def set_override_remote_mirror_available
    enabled = read_attribute(:enabled)

    project.update(remote_mirror_available_overridden: enabled)
  end

  def write_new_remote_name
    self.remote_name = "remote_mirror_#{SecureRandom.hex}"
  end

  def refresh_remote
    return unless project

    # Before adding a new remote we have to delete the data from
    # the previous remote name
    prev_remote_name = remote_name
    run_after_commit do
      project.repository.schedule_remove_remote(prev_remote_name)
    end

    write_new_remote_name
    project.repository.add_remote(remote_name, url)
  end

  def remove_remote
    return unless project # could be pending to delete so don't need to touch the git repository

    project.repository.schedule_remove_remote(remote_name)
  end

  def mirror_url_changed?
    url_changed? || encrypted_credentials_changed?
  end
end
