require 'spec_helper'

describe Gitlab::Geo::CronManager, :geo do
  include ::EE::GeoHelpers

  def job(name)
    Sidekiq::Cron::Job.find(name)
  end

  subject(:manager) { described_class.new }

  describe '#execute' do
    set(:primary) { create(:geo_node, :primary) }
    set(:secondary) { create(:geo_node) }

    def init_cron_job(job_name, class_name)
      job = Sidekiq::Cron::Job.new(
        name: job_name,
        cron: '0 * * * *',
        class: class_name
      )

      job.enable!
    end

    JOBS = %w(ldap_test geo_repository_sync_worker geo_file_download_dispatch_worker geo_metrics_update_worker).freeze

    before(:all) do
      JOBS.each { |name| init_cron_job(name, name.camelize) }
    end

    after(:all) do
      JOBS.each { |name| job(name)&.destroy }
    end

    let(:common_jobs) { [job('geo_metrics_update_worker')] }
    let(:ldap_test_job) { job('ldap_test') }

    let(:secondary_jobs) do
      [
        job('geo_file_download_dispatch_worker'),
        job('geo_repository_sync_worker')
      ]
    end

    context 'on a Geo primary' do
      before do
        stub_current_geo_node(primary)

        manager.execute
      end

      it 'disables secondary-only jobs' do
        secondary_jobs.each { |job| expect(job).not_to be_enabled }
      end

      it 'enables common jobs' do
        expect(common_jobs).to all(be_enabled)
      end

      it 'enables non-geo jobs' do
        expect(ldap_test_job).to be_enabled
      end
    end

    context 'on a Geo secondary' do
      before do
        stub_current_geo_node(secondary)

        manager.execute
      end

      it 'enables secondary-only jobs' do
        expect(secondary_jobs).to all(be_enabled)
      end

      it 'enables common jobs' do
        expect(common_jobs).to all(be_enabled)
      end

      it 'disables non-geo jobs' do
        expect(ldap_test_job).not_to be_enabled
      end
    end

    context 'on a non-Geo node' do
      before do
        stub_current_geo_node(nil)

        manager.execute
      end

      it 'disables secondary-only jobs' do
        secondary_jobs.each { |job| expect(job).not_to be_enabled }
      end

      it 'disables common jobs' do
        common_jobs.each { |job| expect(job).not_to be_enabled }
      end

      it 'enables non-geo jobs' do
        expect(ldap_test_job).to be_enabled
      end
    end
  end

  describe '#create_watcher!' do
    it 'creates a Geo::SidekiqCronConfigWorker sidekiq-cron job' do
      manager.create_watcher!

      created = job('geo_sidekiq_cron_config_worker')

      expect(created).not_to be_nil
      expect(created.klass).to eq('Geo::SidekiqCronConfigWorker')
      expect(created.cron).to eq('*/1 * * * *')
      expect(created.name).to eq('geo_sidekiq_cron_config_worker')
    end
  end
end
