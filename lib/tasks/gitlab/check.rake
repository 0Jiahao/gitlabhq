namespace :gitlab do
  desc "GitLab | Check the configuration of GitLab and its environment"
  task check: %w{gitlab:gitlab_shell:check
                 gitlab:sidekiq:check
                 gitlab:incoming_email:check
                 gitlab:ldap:check
                 gitlab:app:check}



  namespace :app do
    desc "GitLab | Check the configuration of the GitLab Rails app"
    task check: :environment  do
      warn_user_is_not_gitlab
      start_checking "GitLab"

      check_git_config
      check_database_config_exists
      check_migrations_are_up
      check_orphaned_group_members
      check_gitlab_config_exists
      check_gitlab_config_not_outdated
      check_log_writable
      check_tmp_writable
      check_uploads
      check_init_script_exists
      check_init_script_up_to_date
      check_projects_have_namespace
      check_redis_version
      check_ruby_version
      check_git_version
      check_active_users
      check_elasticsearch if ApplicationSetting.current.elasticsearch_indexing?

      finished_checking "GitLab"
    end


    # Checks
    ########################

    def check_git_config
      print "Git configured with autocrlf=input? ... "

      options = {
        "core.autocrlf" => "input"
      }

      correct_options = options.map do |name, value|
        run_command(%W(#{Gitlab.config.git.bin_path} config --global --get #{name})).try(:squish) == value
      end

      if correct_options.all?
        puts "yes".color(:green)
      else
        print "Trying to fix Git error automatically. ..."

        if auto_fix_git_config(options)
          puts "Success".color(:green)
        else
          puts "Failed".color(:red)
          try_fixing_it(
            sudo_gitlab("\"#{Gitlab.config.git.bin_path}\" config --global core.autocrlf \"#{options["core.autocrlf"]}\"")
          )
          for_more_information(
            see_installation_guide_section "GitLab"
          )
        end
      end
    end

    def check_database_config_exists
      print "Database config exists? ... "

      database_config_file = Rails.root.join("config", "database.yml")

      if File.exist?(database_config_file)
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Copy config/database.yml.<your db> to config/database.yml",
          "Check that the information in config/database.yml is correct"
        )
        for_more_information(
          see_database_guide,
          "http://guides.rubyonrails.org/getting_started.html#configuring-a-database"
        )
        fix_and_rerun
      end
    end

    def check_gitlab_config_exists
      print "GitLab config exists? ... "

      gitlab_config_file = Rails.root.join("config", "gitlab.yml")

      if File.exist?(gitlab_config_file)
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Copy config/gitlab.yml.example to config/gitlab.yml",
          "Update config/gitlab.yml to match your setup"
        )
        for_more_information(
          see_installation_guide_section "GitLab"
        )
        fix_and_rerun
      end
    end

    def check_gitlab_config_not_outdated
      print "GitLab config outdated? ... "

      gitlab_config_file = Rails.root.join("config", "gitlab.yml")
      unless File.exist?(gitlab_config_file)
        puts "can't check because of previous errors".color(:magenta)
      end

      # omniauth or ldap could have been deleted from the file
      unless Gitlab.config['git_host']
        puts "no".color(:green)
      else
        puts "yes".color(:red)
        try_fixing_it(
          "Backup your config/gitlab.yml",
          "Copy config/gitlab.yml.example to config/gitlab.yml",
          "Update config/gitlab.yml to match your setup"
        )
        for_more_information(
          see_installation_guide_section "GitLab"
        )
        fix_and_rerun
      end
    end

    def check_init_script_exists
      print "Init script exists? ... "

      if omnibus_gitlab?
        puts 'skipped (omnibus-gitlab has no init script)'.color(:magenta)
        return
      end

      script_path = "/etc/init.d/gitlab"

      if File.exist?(script_path)
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Install the init script"
        )
        for_more_information(
          see_installation_guide_section "Install Init Script"
        )
        fix_and_rerun
      end
    end

    def check_init_script_up_to_date
      print "Init script up-to-date? ... "

      if omnibus_gitlab?
        puts 'skipped (omnibus-gitlab has no init script)'.color(:magenta)
        return
      end

      recipe_path = Rails.root.join("lib/support/init.d/", "gitlab")
      script_path = "/etc/init.d/gitlab"

      unless File.exist?(script_path)
        puts "can't check because of previous errors".color(:magenta)
        return
      end

      recipe_content = File.read(recipe_path)
      script_content = File.read(script_path)

      if recipe_content == script_content
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Redownload the init script"
        )
        for_more_information(
          see_installation_guide_section "Install Init Script"
        )
        fix_and_rerun
      end
    end

    def check_migrations_are_up
      print "All migrations up? ... "

      migration_status, _ = Gitlab::Popen.popen(%W(bundle exec rake db:migrate:status))

      unless migration_status =~ /down\s+\d{14}/
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          sudo_gitlab("bundle exec rake db:migrate RAILS_ENV=production")
        )
        fix_and_rerun
      end
    end

    def check_orphaned_group_members
      print "Database contains orphaned GroupMembers? ... "
      if GroupMember.where("user_id not in (select id from users)").count > 0
        puts "yes".color(:red)
        try_fixing_it(
          "You can delete the orphaned records using something along the lines of:",
          sudo_gitlab("bundle exec rails runner -e production 'GroupMember.where(\"user_id NOT IN (SELECT id FROM users)\").delete_all'")
        )
      else
        puts "no".color(:green)
      end
    end

    def check_log_writable
      print "Log directory writable? ... "

      log_path = Rails.root.join("log")

      if File.writable?(log_path)
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "sudo chown -R gitlab #{log_path}",
          "sudo chmod -R u+rwX #{log_path}"
        )
        for_more_information(
          see_installation_guide_section "GitLab"
        )
        fix_and_rerun
      end
    end

    def check_tmp_writable
      print "Tmp directory writable? ... "

      tmp_path = Rails.root.join("tmp")

      if File.writable?(tmp_path)
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "sudo chown -R gitlab #{tmp_path}",
          "sudo chmod -R u+rwX #{tmp_path}"
        )
        for_more_information(
          see_installation_guide_section "GitLab"
        )
        fix_and_rerun
      end
    end

    def check_uploads
      print "Uploads directory setup correctly? ... "

      unless File.directory?(Rails.root.join('public/uploads'))
        puts "no".color(:red)
        try_fixing_it(
          "sudo -u #{gitlab_user} mkdir #{Rails.root}/public/uploads"
        )
        for_more_information(
          see_installation_guide_section "GitLab"
        )
        fix_and_rerun
        return
      end

      upload_path = File.realpath(Rails.root.join('public/uploads'))
      upload_path_tmp = File.join(upload_path, 'tmp')

      if File.stat(upload_path).mode == 040700
        unless Dir.exists?(upload_path_tmp)
          puts 'skipped (no tmp uploads folder yet)'.color(:magenta)
          return
        end

        # If tmp upload dir has incorrect permissions, assume others do as well
        # Verify drwx------ permissions
        if File.stat(upload_path_tmp).mode == 040700 && File.owned?(upload_path_tmp)
          puts "yes".color(:green)
        else
          puts "no".color(:red)
          try_fixing_it(
            "sudo chown -R #{gitlab_user} #{upload_path}",
            "sudo find #{upload_path} -type f -exec chmod 0644 {} \\;",
            "sudo find #{upload_path} -type d -not -path #{upload_path} -exec chmod 0700 {} \\;"
          )
          for_more_information(
            see_installation_guide_section "GitLab"
          )
          fix_and_rerun
        end
      else
        puts "no".color(:red)
        try_fixing_it(
          "sudo chmod 700 #{upload_path}"
        )
        for_more_information(
          see_installation_guide_section "GitLab"
        )
        fix_and_rerun
      end
    end

    def check_redis_version
      min_redis_version = "2.8.0"
      print "Redis version >= #{min_redis_version}? ... "

      redis_version = run_command(%W(redis-cli --version))
      redis_version = redis_version.try(:match, /redis-cli (\d+\.\d+\.\d+)/)
      if redis_version &&
          (Gem::Version.new(redis_version[1]) > Gem::Version.new(min_redis_version))
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Update your redis server to a version >= #{min_redis_version}"
        )
        for_more_information(
          "gitlab-public-wiki/wiki/Trouble-Shooting-Guide in section sidekiq"
        )
        fix_and_rerun
      end
    end
  end

  namespace :gitlab_shell do
    desc "GitLab | Check the configuration of GitLab Shell"
    task check: :environment  do
      warn_user_is_not_gitlab
      start_checking "GitLab Shell"

      check_gitlab_shell
      check_repo_base_exists
      check_repo_base_is_not_symlink
      check_repo_base_user_and_group
      check_repo_base_permissions
      check_repos_hooks_directory_is_link
      check_gitlab_shell_self_test

      finished_checking "GitLab Shell"
    end


    # Checks
    ########################

    def check_repo_base_exists
      puts "Repo base directory exists?"

      Gitlab.config.repositories.storages.each do |name, repo_base_path|
        print "#{name}... "

        if File.exist?(repo_base_path)
          puts "yes".color(:green)
        else
          puts "no".color(:red)
          puts "#{repo_base_path} is missing".color(:red)
          try_fixing_it(
            "This should have been created when setting up GitLab Shell.",
            "Make sure it's set correctly in config/gitlab.yml",
            "Make sure GitLab Shell is installed correctly."
          )
          for_more_information(
            see_installation_guide_section "GitLab Shell"
          )
          fix_and_rerun
        end
      end
    end

    def check_repo_base_is_not_symlink
      puts "Repo storage directories are symlinks?"

      Gitlab.config.repositories.storages.each do |name, repo_base_path|
        print "#{name}... "

        unless File.exist?(repo_base_path)
          puts "can't check because of previous errors".color(:magenta)
          return
        end

        unless File.symlink?(repo_base_path)
          puts "no".color(:green)
        else
          puts "yes".color(:red)
          try_fixing_it(
            "Make sure it's set to the real directory in config/gitlab.yml"
          )
          fix_and_rerun
        end
      end
    end

    def check_repo_base_permissions
      puts "Repo paths access is drwxrws---?"

      Gitlab.config.repositories.storages.each do |name, repo_base_path|
        print "#{name}... "

        unless File.exist?(repo_base_path)
          puts "can't check because of previous errors".color(:magenta)
          return
        end

        if File.stat(repo_base_path).mode.to_s(8).ends_with?("2770")
          puts "yes".color(:green)
        else
          puts "no".color(:red)
          try_fixing_it(
            "sudo chmod -R ug+rwX,o-rwx #{repo_base_path}",
            "sudo chmod -R ug-s #{repo_base_path}",
            "sudo find #{repo_base_path} -type d -print0 | sudo xargs -0 chmod g+s"
          )
          for_more_information(
            see_installation_guide_section "GitLab Shell"
          )
          fix_and_rerun
        end
      end
    end

    def check_repo_base_user_and_group
      gitlab_shell_ssh_user = Gitlab.config.gitlab_shell.ssh_user
      gitlab_shell_owner_group = Gitlab.config.gitlab_shell.owner_group
      puts "Repo paths owned by #{gitlab_shell_ssh_user}:#{gitlab_shell_owner_group}?"

      Gitlab.config.repositories.storages.each do |name, repo_base_path|
        print "#{name}... "

        unless File.exist?(repo_base_path)
          puts "can't check because of previous errors".color(:magenta)
          return
        end

        uid = uid_for(gitlab_shell_ssh_user)
        gid = gid_for(gitlab_shell_owner_group)
        if File.stat(repo_base_path).uid == uid && File.stat(repo_base_path).gid == gid
          puts "yes".color(:green)
        else
          puts "no".color(:red)
          puts "  User id for #{gitlab_shell_ssh_user}: #{uid}. Groupd id for #{gitlab_shell_owner_group}: #{gid}".color(:blue)
          try_fixing_it(
            "sudo chown -R #{gitlab_shell_ssh_user}:#{gitlab_shell_owner_group} #{repo_base_path}"
          )
          for_more_information(
            see_installation_guide_section "GitLab Shell"
          )
          fix_and_rerun
        end
      end
    end

    def check_repos_hooks_directory_is_link
      print "hooks directories in repos are links: ... "

      gitlab_shell_hooks_path = Gitlab.config.gitlab_shell.hooks_path

      unless Project.count > 0
        puts "can't check, you have no projects".color(:magenta)
        return
      end
      puts ""

      Project.find_each(batch_size: 100) do |project|
        print sanitized_message(project)
        project_hook_directory = File.join(project.repository.path_to_repo, "hooks")

        if project.empty_repo?
          puts "repository is empty".color(:magenta)
        elsif File.directory?(project_hook_directory) && File.directory?(gitlab_shell_hooks_path) &&
            (File.realpath(project_hook_directory) == File.realpath(gitlab_shell_hooks_path))
          puts 'ok'.color(:green)
        else
          puts "wrong or missing hooks".color(:red)
          try_fixing_it(
            sudo_gitlab("#{File.join(gitlab_shell_path, 'bin/create-hooks')} #{repository_storage_paths_args.join(' ')}"),
            'Check the hooks_path in config/gitlab.yml',
            'Check your gitlab-shell installation'
          )
          for_more_information(
            see_installation_guide_section "GitLab Shell"
          )
          fix_and_rerun
        end

      end
    end

    def check_gitlab_shell_self_test
      gitlab_shell_repo_base = gitlab_shell_path
      check_cmd = File.expand_path('bin/check', gitlab_shell_repo_base)
      puts "Running #{check_cmd}"
      if system(check_cmd, chdir: gitlab_shell_repo_base)
        puts 'gitlab-shell self-check successful'.color(:green)
      else
        puts 'gitlab-shell self-check failed'.color(:red)
        try_fixing_it(
          'Make sure GitLab is running;',
          'Check the gitlab-shell configuration file:',
          sudo_gitlab("editor #{File.expand_path('config.yml', gitlab_shell_repo_base)}")
        )
        fix_and_rerun
      end
    end

    def check_projects_have_namespace
      print "projects have namespace: ... "

      unless Project.count > 0
        puts "can't check, you have no projects".color(:magenta)
        return
      end
      puts ""

      Project.find_each(batch_size: 100) do |project|
        print sanitized_message(project)

        if project.namespace
          puts "yes".color(:green)
        else
          puts "no".color(:red)
          try_fixing_it(
            "Migrate global projects"
          )
          for_more_information(
            "doc/update/5.4-to-6.0.md in section \"#global-projects\""
          )
          fix_and_rerun
        end
      end
    end

    # Helper methods
    ########################

    def gitlab_shell_path
      Gitlab.config.gitlab_shell.path
    end

    def gitlab_shell_version
      Gitlab::Shell.new.version
    end

    def gitlab_shell_major_version
      Gitlab::Shell.version_required.split('.')[0].to_i
    end

    def gitlab_shell_minor_version
      Gitlab::Shell.version_required.split('.')[1].to_i
    end

    def gitlab_shell_patch_version
      Gitlab::Shell.version_required.split('.')[2].to_i
    end
  end



  namespace :sidekiq do
    desc "GitLab | Check the configuration of Sidekiq"
    task check: :environment  do
      warn_user_is_not_gitlab
      start_checking "Sidekiq"

      check_sidekiq_running
      only_one_sidekiq_running

      finished_checking "Sidekiq"
    end


    # Checks
    ########################

    def check_sidekiq_running
      print "Running? ... "

      if sidekiq_process_count > 0
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          sudo_gitlab("RAILS_ENV=production bin/background_jobs start")
        )
        for_more_information(
          see_installation_guide_section("Install Init Script"),
          "see log/sidekiq.log for possible errors"
        )
        fix_and_rerun
      end
    end

    def only_one_sidekiq_running
      process_count = sidekiq_process_count
      return if process_count.zero?

      print 'Number of Sidekiq processes ... '
      if process_count == 1
        puts '1'.color(:green)
      else
        puts "#{process_count}".color(:red)
        try_fixing_it(
          'sudo service gitlab stop',
          "sudo pkill -u #{gitlab_user} -f sidekiq",
          "sleep 10 && sudo pkill -9 -u #{gitlab_user} -f sidekiq",
          'sudo service gitlab start'
        )
        fix_and_rerun
      end
    end

    def sidekiq_process_count
      ps_ux, _ = Gitlab::Popen.popen(%W(ps ux))
      ps_ux.scan(/sidekiq \d+\.\d+\.\d+/).count
    end
  end


  namespace :incoming_email do
    desc "GitLab | Check the configuration of Reply by email"
    task check: :environment  do
      warn_user_is_not_gitlab
      start_checking "Reply by email"

      if Gitlab.config.incoming_email.enabled
        check_imap_authentication

        if Rails.env.production?
          check_initd_configured_correctly
          check_mail_room_running
        else
          check_foreman_configured_correctly
        end
      else
        puts 'Reply by email is disabled in config/gitlab.yml'
      end

      finished_checking "Reply by email"
    end


    # Checks
    ########################

    def check_initd_configured_correctly
      print "Init.d configured correctly? ... "

      if omnibus_gitlab?
        puts 'skipped (omnibus-gitlab has no init script)'.color(:magenta)
        return
      end

      path = "/etc/default/gitlab"

      if File.exist?(path) && File.read(path).include?("mail_room_enabled=true")
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Enable mail_room in the init.d configuration."
        )
        for_more_information(
          "doc/administration/reply_by_email.md"
        )
        fix_and_rerun
      end
    end

    def check_foreman_configured_correctly
      print "Foreman configured correctly? ... "

      path = Rails.root.join("Procfile")

      if File.exist?(path) && File.read(path) =~ /^mail_room:/
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Enable mail_room in your Procfile."
        )
        for_more_information(
          "doc/administration/reply_by_email.md"
        )
        fix_and_rerun
      end
    end

    def check_mail_room_running
      print "MailRoom running? ... "

      path = "/etc/default/gitlab"

      unless File.exist?(path) && File.read(path).include?("mail_room_enabled=true")
        puts "can't check because of previous errors".color(:magenta)
        return
      end

      if mail_room_running?
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          sudo_gitlab("RAILS_ENV=production bin/mail_room start")
        )
        for_more_information(
          see_installation_guide_section("Install Init Script"),
          "see log/mail_room.log for possible errors"
        )
        fix_and_rerun
      end
    end

    def check_imap_authentication
      print "IMAP server credentials are correct? ... "

      config_path = Rails.root.join('config', 'mail_room.yml').to_s
      erb = ERB.new(File.read(config_path))
      erb.filename = config_path
      config_file = YAML.load(erb.result)

      config = config_file[:mailboxes].first

      if config
        begin
          imap = Net::IMAP.new(config[:host], port: config[:port], ssl: config[:ssl])
          imap.starttls if config[:start_tls]
          imap.login(config[:email], config[:password])
          connected = true
        rescue
          connected = false
        end
      end

      if connected
        puts "yes".color(:green)
      else
        puts "no".color(:red)
        try_fixing_it(
          "Check that the information in config/gitlab.yml is correct"
        )
        for_more_information(
          "doc/administration/reply_by_email.md"
        )
        fix_and_rerun
      end
    end

    def mail_room_running?
      ps_ux, _ = Gitlab::Popen.popen(%W(ps ux))
      ps_ux.include?("mail_room")
    end
  end

  namespace :ldap do
    task :check, [:limit] => :environment do |_, args|
      # Only show up to 100 results because LDAP directories can be very big.
      # This setting only affects the `rake gitlab:check` script.
      args.with_defaults(limit: 100)
      warn_user_is_not_gitlab
      start_checking "LDAP"

      if Gitlab::LDAP::Config.enabled?
        check_ldap(args.limit)
      else
        puts 'LDAP is disabled in config/gitlab.yml'
      end

      finished_checking "LDAP"
    end

    def check_ldap(limit)
      servers = Gitlab::LDAP::Config.providers

      servers.each do |server|
        puts "Server: #{server}"

        begin
          Gitlab::LDAP::Adapter.open(server) do |adapter|
            check_ldap_auth(adapter)

            puts "LDAP users with access to your GitLab server (only showing the first #{limit} results)"

            users = adapter.users(adapter.config.uid, '*', limit)
            users.each do |user|
              puts "\tDN: #{user.dn}\t #{adapter.config.uid}: #{user.uid}"
            end
          end
        rescue Net::LDAP::ConnectionRefusedError, Errno::ECONNREFUSED => e
          puts "Could not connect to the LDAP server: #{e.message}".color(:red)
        end
      end
    end

    def check_ldap_auth(adapter)
      auth = adapter.config.has_auth?

      if auth && adapter.ldap.bind
        message = 'Success'.color(:green)
      elsif auth
        message = 'Failed. Check `bind_dn` and `password` configuration values'.color(:red)
      else
        message = 'Anonymous. No `bind_dn` or `password` configured'.color(:yellow)
      end

      puts "LDAP authentication... #{message}"
    end
  end

  namespace :repo do
    desc "GitLab | Check the integrity of the repositories managed by GitLab"
    task check: :environment do
      Gitlab.config.repositories.storages.each do |name, path|
        namespace_dirs = Dir.glob(File.join(path, '*'))

        namespace_dirs.each do |namespace_dir|
          repo_dirs = Dir.glob(File.join(namespace_dir, '*'))
          repo_dirs.each { |repo_dir| check_repo_integrity(repo_dir) }
        end
      end
    end
  end

  namespace :user do
    desc "GitLab | Check the integrity of a specific user's repositories"
    task :check_repos, [:username] => :environment do |t, args|
      username = args[:username] || prompt("Check repository integrity for fsername? ".color(:blue))
      user = User.find_by(username: username)
      if user
        repo_dirs = user.authorized_projects.map do |p|
                      File.join(
                        p.repository_storage_path,
                        "#{p.path_with_namespace}.git"
                      )
                    end

        repo_dirs.each { |repo_dir| check_repo_integrity(repo_dir) }
      else
        puts "\nUser '#{username}' not found".color(:red)
      end
    end
  end

  namespace :geo do
    desc 'GitLab | Check Geo configuration and dependencies'
    task check: :environment do
      warn_user_is_not_gitlab
      start_checking 'Geo'

      check_geo_license
      check_geo_enabled
      check_nodes_http_connection

      finished_checking 'Geo'
    end

    # Checks
    ########################

    def check_geo_license
      print 'GitLab Geo is available ... '
      if Gitlab::Geo.license_allows?
        puts 'yes'.color(:green)
      else
        puts 'no'.color(:red)

        try_fixing_it(
          'Upload a new license that includes GitLab Geo feature'
        )

        for_more_information(see_geo_features_page)
      end
    end

    def check_geo_enabled
      print 'GitLab Geo is enabled ... '
      if Gitlab::Geo.enabled?
        puts 'yes'.color(:green)
      else
        puts 'no'.color(:red)

        try_fixing_it(
          'Follow Geo Setup instructions to configure primary and secondary nodes'
        )

        for_more_information(see_geo_docs)
      end
    end

    def check_nodes_http_connection
      return unless Gitlab::Geo.enabled?

      if Gitlab::Geo.primary?
        Gitlab::Geo.secondary_nodes.each do |node|
          print "Can connect to secondary node: '#{node.url}' ... "
          check_gitlab_geo_node(node)
        end
      end

      if Gitlab::Geo.secondary?
        print 'Can connect to the primary node ... '
        check_gitlab_geo_node(Gitlab::Geo.primary_node)
      end
    end
  end

  # Helper methods
  ##########################

  def fix_and_rerun
    puts "  Please #{"fix the error above"} and rerun the checks.".color(:red)
  end

  def for_more_information(*sources)
    sources = sources.shift if sources.first.is_a?(Array)

    puts "  For more information see:".color(:blue)
    sources.each do |source|
      puts "  #{source}"
    end
  end

  def finished_checking(component)
    puts ""
    puts "Checking #{component.color(:yellow)} ... #{"Finished".color(:green)}"
    puts ""
  end

  def see_database_guide
    "doc/install/databases.md"
  end

  def see_installation_guide_section(section)
    "doc/install/installation.md in section \"#{section}\""
  end

  def see_geo_features_page
    'https://about.gitlab.com/features/gitlab-geo/'
  end

  def see_geo_docs
    'doc/gitlab-geo/README.md'
  end

  def see_custom_certificate_doc
    'https://docs.gitlab.com/omnibus/common_installation_problems/README.html#using-self-signed-certificate-or-custom-certificate-authorities'
  end

  def sudo_gitlab(command)
    "sudo -u #{gitlab_user} -H #{command}"
  end

  def gitlab_user
    Gitlab.config.gitlab.user
  end

  def start_checking(component)
    puts "Checking #{component.color(:yellow)} ..."
    puts ""
  end

  def try_fixing_it(*steps)
    steps = steps.shift if steps.first.is_a?(Array)

    puts "  Try fixing it:".color(:blue)
    steps.each do |step|
      puts "  #{step}"
    end
  end

  def check_gitlab_shell
    required_version = Gitlab::VersionInfo.new(gitlab_shell_major_version, gitlab_shell_minor_version, gitlab_shell_patch_version)
    current_version = Gitlab::VersionInfo.parse(gitlab_shell_version)

    print "GitLab Shell version >= #{required_version} ? ... "
    if current_version.valid? && required_version <= current_version
      puts "OK (#{current_version})".color(:green)
    else
      puts "FAIL. Please update gitlab-shell to #{required_version} from #{current_version}".color(:red)
    end
  end

  def check_ruby_version
    required_version = Gitlab::VersionInfo.new(2, 1, 0)
    current_version = Gitlab::VersionInfo.parse(run_command(%W(ruby --version)))

    print "Ruby version >= #{required_version} ? ... "

    if current_version.valid? && required_version <= current_version
      puts "yes (#{current_version})".color(:green)
    else
      puts "no".color(:red)
      try_fixing_it(
        "Update your ruby to a version >= #{required_version} from #{current_version}"
      )
      fix_and_rerun
    end
  end

  def check_git_version
    required_version = Gitlab::VersionInfo.new(2, 7, 3)
    current_version = Gitlab::VersionInfo.parse(run_command(%W(#{Gitlab.config.git.bin_path} --version)))

    puts "Your git bin path is \"#{Gitlab.config.git.bin_path}\""
    print "Git version >= #{required_version} ? ... "

    if current_version.valid? && required_version <= current_version
      puts "yes (#{current_version})".color(:green)
    else
      puts "no".color(:red)
      try_fixing_it(
        "Update your git to a version >= #{required_version} from #{current_version}"
      )
      fix_and_rerun
    end
  end

  def check_active_users
    puts "Active users: #{User.active.count}"
  end

  def omnibus_gitlab?
    Dir.pwd == '/opt/gitlab/embedded/service/gitlab-rails'
  end

  def sanitized_message(project)
    if should_sanitize?
      "#{project.namespace_id.to_s.color(:yellow)}/#{project.id.to_s.color(:yellow)} ... "
    else
      "#{project.name_with_namespace.color(:yellow)} ... "
    end
  end

  def should_sanitize?
    if ENV['SANITIZE'] == "true"
      true
    else
      false
    end
  end

  def check_repo_integrity(repo_dir)
    puts "\nChecking repo at #{repo_dir.color(:yellow)}"

    git_fsck(repo_dir)
    check_config_lock(repo_dir)
    check_ref_locks(repo_dir)
  end

  def git_fsck(repo_dir)
    puts "Running `git fsck`".color(:yellow)
    system(*%W(#{Gitlab.config.git.bin_path} fsck), chdir: repo_dir)
  end

  def check_config_lock(repo_dir)
    config_exists = File.exist?(File.join(repo_dir,'config.lock'))
    config_output = config_exists ? 'yes'.color(:red) : 'no'.color(:green)
    puts "'config.lock' file exists?".color(:yellow) + " ... #{config_output}"
  end

  def check_ref_locks(repo_dir)
    lock_files = Dir.glob(File.join(repo_dir,'refs/heads/*.lock'))
    if lock_files.present?
      puts "Ref lock files exist:".color(:red)
      lock_files.each do |lock_file|
        puts "  #{lock_file}"
      end
    else
      puts "No ref lock files exist".color(:green)
    end
  end

  def check_elasticsearch
    client = Elasticsearch::Client.new(host: ApplicationSetting.current.elasticsearch_host,
                                       port: ApplicationSetting.current.elasticsearch_port)

    print "Elasticsearch version 5.1.x? ... "

    version = Gitlab::VersionInfo.parse(client.info["version"]["number"])

    if version.major == 5 && version.minor == 1
      puts "yes (#{version})".color(:green)
    else
      puts "no, you have #{version}".color(:red)
    end
  end

  def check_gitlab_geo_node(node)
    display_error = Proc.new do |e|
      puts 'no'.color(:red)
      puts '  Reason:'.color(:blue)
      puts "  #{e.message}"
    end

    begin
      response = Net::HTTP.start(node.uri.host, node.uri.port, use_ssl: (node.uri.scheme == 'https')) do |http|
        http.request(Net::HTTP::Get.new(node.uri))
      end

      if response.code_type == Net::HTTPFound
        puts 'yes'.color(:green)
      else
        puts 'no'.color(:red)
      end
    rescue Errno::ECONNREFUSED => e
      display_error.call(e)

      try_fixing_it(
        'Check if the machine is online and GitLab is running',
        'Check your firewall rules and make sure this machine can reach the target machine',
        "Make sure port and protocol are correct: '#{node.url}', or change it in Admin > Geo Nodes"
      )
    rescue SocketError => e
      display_error.call(e)

      if e.cause && e.cause.message.starts_with?('getaddrinfo')
        try_fixing_it(
          'Check if your machine can connect to a DNS server',
          "Check if your machine can resolve DNS for: '#{node.uri.host}'",
          'If machine host is incorrect, change it in Admin > Geo Nodes'
        )
      end
    rescue OpenSSL::SSL::SSLError => e
      display_error.call(e)

      try_fixing_it(
        'If you have a self-signed CA or certificate you need to whitelist it in Omnibus',
      )
      for_more_information(see_custom_certificate_doc)

      try_fixing_it(
        'If you have a valid certificate make sure you have the full certificate chain in the pem file'
      )
    rescue Exception => e
      display_error.call(e)
    end
  end
end
