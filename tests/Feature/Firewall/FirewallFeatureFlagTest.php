<?php

use App\Models\User;
use Illuminate\Support\Facades\Process;

// On a Proxmox host pve-firewall owns the firewall: the installer writes
// LARANODE_FIREWALL_ENABLED=false (and does not install the laranode-ufw sudoers drop-in,
// which is the real gate). The panel must then hide the Firewall page and refuse its routes.

beforeEach(fn () => $this->withoutVite());

function firewallAdmin(): User
{
    return User::factory()->create(['role' => 'admin']);
}

test('firewall is enabled by default (non-Proxmox hosts unchanged)', function () {
    expect(config('laranode.firewall_enabled'))->toBeTrue();
});

test('every firewall route answers 404 when the firewall is disabled', function () {
    Process::fake();
    config(['laranode.firewall_enabled' => false]);
    $admin = firewallAdmin();

    $this->actingAs($admin)->get('/admin/firewall')->assertNotFound();
    $this->actingAs($admin)->post('/admin/firewall/toggle', ['status' => 'enable'])->assertNotFound();
    $this->actingAs($admin)->post('/admin/firewall/safe-setup')->assertNotFound();
    $this->actingAs($admin)->post('/admin/firewall/rules', ['port' => '8080', 'protocol' => 'tcp'])->assertNotFound();
    $this->actingAs($admin)->delete('/admin/firewall/rules/1')->assertNotFound();

    // nothing reached ufw
    Process::assertNothingRan();
});

test('the firewall page still renders for an admin when enabled', function () {
    Process::fake();
    config(['laranode.firewall_enabled' => true]);

    $this->actingAs(firewallAdmin())->get('/admin/firewall')->assertOk();
});

test('the shared Inertia props tell the sidebar whether the firewall is enabled', function (bool $enabled) {
    config(['laranode.firewall_enabled' => $enabled]);

    $this->actingAs(firewallAdmin())->get('/profile')
        ->assertOk()
        ->assertInertia(fn ($page) => $page->where('features.firewall', $enabled));
})->with([true, false]);
