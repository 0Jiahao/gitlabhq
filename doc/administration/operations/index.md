# Performing Operations in GitLab

Keep your GitLab instance up and running smoothly.

- [Clean up Redis sessions](cleaning_up_redis_sessions.md): Prior to GitLab 7.3,
user sessions did not automatically expire from Redis. If
you have been running a large GitLab server (thousands of users) since before
GitLab 7.3 we recommend cleaning up stale sessions to compact the Redis
database after you upgrade to GitLab 7.3.
- [Moving repositories](moving_repositories.md): Moving all repositories managed
by GitLab to another file system or another server.
- [Sidekiq MemoryKiller](sidekiq_memory_killer.md): Configure Sidekiq MemoryKiller
to restart Sidekiq.
- [Unicorn](unicorn.md): Understand Unicorn and unicorn-worker-killer.
- Speed up SSH operations by [Authorizing SSH users via a fast,
indexed lookup to the GitLab database](fast_ssh_key_lookup.md), and/or
by [doing away with user SSH keys stored on GitLab entirely in favor
of SSH certificates](ssh_certificates.md).
- [Filesystem Performance Benchmarking](filesystem_benchmarking.md): Filesystem
performance can have a big impact on GitLab performance, especially for actions
that read or write Git repositories. This information will help benchmark
filesystem performance against known good and bad real-world systems.
