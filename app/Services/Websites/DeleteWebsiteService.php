<?php

namespace App\Services\Websites;

use App\Models\User;
use App\Models\Website;
use Exception;
use Illuminate\Support\Facades\Process;

class DeleteWebsiteException extends Exception {}

class DeleteWebsiteService
{
    public function __construct(private Website $website, private User $user) {}

    public function handle(): void
    {
        $this->teardownRuntime(); // FIRST — clean shutdown before files deleted (FIXED: review fix #5)
        $this->deleteWebsiteFiles();
        $this->removeVhost();
        $this->syncPhpFpmPools();

        // TODO: delete databases associated with this website

        // if all was successful, delete website from database
        $this->website->delete();
    }

    /**
     * Stop and remove the non-FPM runtime unit before deleting website files.
     * Non-zero exit is logged but does not block deletion.
     * Uses laranode-runtime-manage.sh remove (FIXED: no raw sudo rm, review fix #3).
     */
    private function teardownRuntime(): void
    {
        if ($this->website->runtime === 'php-fpm') {
            return;
        }

        $unit = "laranode-{$this->website->runtime}-{$this->website->url}.service";

        Process::run([
            'sudo',
            config('laranode.laranode_bin_path').'/laranode-runtime-manage.sh',
            'remove',
            $unit,
        ]);
    }

    private function deleteWebsiteFiles(): void
    {
        $deleteWebsite = Process::run('rm -rf '.$this->website->websiteRoot);

        if ($deleteWebsite->failed()) {
            throw new DeleteWebsiteException('Failed to delete website files: '.$deleteWebsite->errorOutput());
        }
    }

    /**
     * Disable and delete the site's Apache vhost through one validated, root-owned script.
     * (Replaces raw `sudo a2dissite` + `sudo rm /etc/apache2/sites-available/*.conf`, whose
     * sudoers glob matched any path and any argument.)
     */
    private function removeVhost(): void
    {
        $result = Process::run([
            'sudo',
            config('laranode.laranode_bin_path').'/laranode-remove-vhost.sh',
            $this->website->url,
        ]);

        if ($result->failed()) {
            throw new DeleteWebsiteException('Failed to remove vhost: '.$result->errorOutput());
        }
    }

    public function syncPhpFpmPools(): void
    {
        $phpVersion = $this->website->phpVersion;
        $thisPhpVersion = $phpVersion->version;

        // check if user has other websites with the same php version, do nothing
        $sitesUsingThisPHPVersion = $this->website
            ->user
            ->websites
            ->where('php_version_id', $phpVersion->id)
            ->count();

        if ($sitesUsingThisPHPVersion > 1) {
            return;
        }

        // user doesn't have other websites with the same php version, remove pool
        $removePhpFpmPool = Process::run([
            'sudo',
            config('laranode.laranode_bin_path').'/laranode-remove-php-fpm-pool-for-user.sh',
            $this->website->user->systemUsername,
            $thisPhpVersion,
        ]);

        if ($removePhpFpmPool->failed()) {
            throw new DeleteWebsiteException('Failed to remove php-fpm pool: '.$removePhpFpmPool->errorOutput());
        }
    }
}
