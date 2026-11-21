import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { vi, describe, it, expect, beforeEach } from 'vitest';
import axios from 'axios';
import Index from './Index';

vi.mock('axios');

vi.mock('@inertiajs/react', () => ({
    Head: ({ title }) => <title>{title}</title>,
    Link: ({ href, children, ...rest }) => <a href={href} {...rest}>{children}</a>,
}));

vi.mock('@/Layouts/AuthenticatedLayout', () => ({
    default: ({ children }) => <div data-testid="layout">{children}</div>,
}));

global.route = (name) => ({ 'power.status': '/admin/power/status', 'power.action': '/admin/power/action' }[name]);

const svc = (over) => ({
    key: 'reverb', label: 'Reverb websockets', managed: true, enabled: false, state: 'running',
    idle_minutes: 10, default_idle_minutes: 10, can_sleep: true, reason: null, supports_idle: true,
    supports_manual: true, memory_mb: 70, ...over,
});

const payload = (services, external = []) => ({ data: { services, external } });

beforeEach(() => {
    vi.clearAllMocks();
});

describe('Power page', () => {
    it('shows one row per service with a state badge', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([
            svc({ key: 'reverb', enabled: true, state: 'sleeping' }),
            svc({ key: 'queue', label: 'Queue worker', supports_idle: false, supports_manual: true, state: 'running' }),
        ]));
        render(<Index />);
        expect(await screen.findByText('Reverb websockets')).toBeInTheDocument();
        expect(screen.getByTestId('state-reverb')).toHaveTextContent(/sleeping/i);
        expect(screen.getByTestId('state-queue')).toHaveTextContent(/running/i);
    });

    it('toggle on enables sleep with the idle minutes from the input', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb' })]));
        axios.post = vi.fn().mockResolvedValue({ data: { ok: true } });
        render(<Index />);
        await screen.findByText('Reverb websockets');

        const idle = screen.getByLabelText(/idle minutes for reverb/i);
        await userEvent.clear(idle);
        await userEvent.type(idle, '25');
        await userEvent.click(screen.getByRole('checkbox', { name: /sleep reverb/i }));

        await waitFor(() => expect(axios.post).toHaveBeenCalledWith('/admin/power/action', { key: 'reverb', action: 'enable', idle_minutes: 25 }));
    });

    it('toggle off disables sleep (no idle argument)', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb', enabled: true, state: 'sleeping' })]));
        axios.post = vi.fn().mockResolvedValue({ data: { ok: true } });
        render(<Index />);
        await screen.findByText('Reverb websockets');
        await userEvent.click(screen.getByRole('checkbox', { name: /sleep reverb/i }));
        await waitFor(() => expect(axios.post).toHaveBeenCalledWith('/admin/power/action', { key: 'reverb', action: 'disable' }));
    });

    it('manual wake is offered for a sleeping service and posts wake', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb', enabled: true, state: 'sleeping' })]));
        axios.post = vi.fn().mockResolvedValue({ data: { ok: true } });
        render(<Index />);
        await screen.findByText('Reverb websockets');
        await userEvent.click(screen.getByRole('button', { name: /wake reverb/i }));
        await waitFor(() => expect(axios.post).toHaveBeenCalledWith('/admin/power/action', { key: 'reverb', action: 'wake' }));
        expect(screen.queryByRole('button', { name: /sleep reverb now/i })).not.toBeInTheDocument();
    });

    it('manual sleep is offered for a running service with sleep enabled', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb', enabled: true, state: 'running' })]));
        axios.post = vi.fn().mockResolvedValue({ data: { ok: true } });
        render(<Index />);
        await screen.findByText('Reverb websockets');
        await userEvent.click(screen.getByRole('button', { name: /sleep reverb now/i }));
        await waitFor(() => expect(axios.post).toHaveBeenCalledWith('/admin/power/action', { key: 'reverb', action: 'sleep' }));
    });

    it('no wake/sleep buttons when sleep is off', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb', enabled: false })]));
        render(<Index />);
        await screen.findByText('Reverb websockets');
        expect(screen.queryByRole('button', { name: /wake reverb/i })).not.toBeInTheDocument();
        expect(screen.queryByRole('button', { name: /sleep reverb now/i })).not.toBeInTheDocument();
    });

    it('a service that cannot sleep shows the reason and a disabled toggle', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'hostdb', label: 'Hosting database', can_sleep: false, reason: 'panel_db' })]));
        render(<Index />);
        await screen.findByText('Hosting database');
        expect(screen.getByText(/cannot sleep: panel DB/i)).toBeInTheDocument();
        expect(screen.getByRole('checkbox', { name: /sleep hostdb/i })).toBeDisabled();
    });

    it('an AppArmor-blocked hosting DB shows why and cannot be toggled', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'hostdb', label: 'Hosting database', can_sleep: false, reason: 'apparmor' })]));
        render(<Index />);
        await screen.findByText('Hosting database');
        expect(screen.getByText(/cannot sleep: AppArmor profile blocks the moved DB socket/i)).toBeInTheDocument();
        expect(screen.getByRole('checkbox', { name: /sleep hostdb/i })).toBeDisabled();
    });

    it('unmanaged services render as external and have no controls', async () => {
        axios.get = vi.fn().mockResolvedValue(payload(
            [svc({ key: 'hostdb', label: 'Hosting database', managed: false, state: 'external', can_sleep: false, reason: 'external' })],
            [{ service: 'postgresql', label: 'postgresql' }],
        ));
        render(<Index />);
        await screen.findByText('Hosting database');
        expect(screen.getByTestId('state-hostdb')).toHaveTextContent(/external/i);
        expect(screen.getByRole('checkbox', { name: /sleep hostdb/i })).toBeDisabled();
        const ext = screen.getByTestId('external-list');
        expect(within(ext).getByText(/postgresql/)).toBeInTheDocument();
        expect(ext).toHaveTextContent(/never managed/i);
    });

    it('shows the server error when the request is refused', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb' })]));
        axios.post = vi.fn().mockRejectedValue({ response: { data: { message: 'Panel database lives on this instance' } } });
        render(<Index />);
        await screen.findByText('Reverb websockets');
        await userEvent.click(screen.getByRole('checkbox', { name: /sleep reverb/i }));
        expect(await screen.findByText(/Panel database lives on this instance/)).toBeInTheDocument();
    });

    it('rejects an idle value outside 1-1440 before calling the server', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'reverb' })]));
        axios.post = vi.fn();
        render(<Index />);
        await screen.findByText('Reverb websockets');
        const idle = screen.getByLabelText(/idle minutes for reverb/i);
        await userEvent.clear(idle);
        await userEvent.type(idle, '0');
        await userEvent.click(screen.getByRole('checkbox', { name: /sleep reverb/i }));
        expect(axios.post).not.toHaveBeenCalled();
        expect(await screen.findByText(/1 and 1440/)).toBeInTheDocument();
    });

    it('idle input is not shown for services without an idle setting (queue)', async () => {
        axios.get = vi.fn().mockResolvedValue(payload([svc({ key: 'queue', label: 'Queue worker', supports_idle: false })]));
        render(<Index />);
        await screen.findByText('Queue worker');
        expect(screen.queryByLabelText(/idle minutes for queue/i)).not.toBeInTheDocument();
    });
});
