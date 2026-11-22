import { render, screen } from '@testing-library/react';
import { test, expect, vi, beforeEach } from 'vitest';
import SidebarNavi from './SidebarNavi';

// The Firewall link follows the shared `features.firewall` prop (false on a Proxmox host,
// where pve-firewall owns the firewall). A missing prop keeps the link (older panels).
const page = vi.hoisted(() => ({ props: {} }));

vi.mock('@inertiajs/react', () => ({
    usePage: () => page,
    Link: ({ href, children, ...rest }) => <a href={href} {...rest}>{children}</a>,
}));

global.route = (name) => `/${name}`;

const admin = { id: 1, role: 'admin' };

beforeEach(() => {
    page.props = { auth: { user: admin } };
});

test('admin sees the Firewall link when the firewall is enabled', () => {
    page.props.features = { firewall: true };
    render(<SidebarNavi isCollapsed={false} setIsCollapsed={vi.fn()} />);
    expect(screen.getByText('Firewall').closest('a')).toHaveAttribute('href', '/firewall.index');
});

test('admin does not see the Firewall link when the firewall is disabled', () => {
    page.props.features = { firewall: false };
    render(<SidebarNavi isCollapsed={false} setIsCollapsed={vi.fn()} />);
    expect(screen.queryByText('Firewall')).toBeNull();
});

test('the Firewall link stays when the features prop is absent', () => {
    render(<SidebarNavi isCollapsed={false} setIsCollapsed={vi.fn()} />);
    expect(screen.getByText('Firewall')).toBeInTheDocument();
});

test('a non-admin never sees the Firewall link', () => {
    page.props = { auth: { user: { id: 2, role: 'user' } }, features: { firewall: true } };
    render(<SidebarNavi isCollapsed={false} setIsCollapsed={vi.fn()} />);
    expect(screen.queryByText('Firewall')).toBeNull();
});
