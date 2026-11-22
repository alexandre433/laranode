<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * The Firewall page is off where the panel does not own the firewall (a Proxmox host:
 * pve-firewall does). The installer writes LARANODE_FIREWALL_ENABLED=false there and does
 * not install the laranode-ufw sudoers drop-in, which is the real gate; this keeps the
 * page and its routes out of reach so the panel never offers what it cannot do.
 */
class FirewallEnabledMiddleware
{
    public function handle(Request $request, Closure $next): Response
    {
        abort_unless((bool) config('laranode.firewall_enabled', true), 404);

        return $next($request);
    }
}
