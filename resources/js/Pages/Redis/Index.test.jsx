import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { test, expect, vi, beforeEach, afterEach } from 'vitest';
import RedisIndex from './Index';
import { fmtBytes, fmtRate, fmtPct, fmtUptime, memLevel } from './format';

vi.mock('@inertiajs/react', () => ({
    Head: ({ title }) => <title>{title}</title>,
    usePage: () => ({ props: { auth: { user: { id: 1, role: 'admin' } }, flash: {} } }),
    Link: ({ href, children, ...rest }) => <a href={href} {...rest}>{children}</a>,
}));
vi.mock('react-icons/tb', () => ({ TbServer2: () => <span>icon</span> }));
vi.mock('@/Layouts/AuthenticatedLayout', () => ({
    default: ({ children, header }) => (
        <div>
            <div data-testid="header">{header}</div>
            <div data-testid="content">{children}</div>
        </div>
    ),
}));
vi.mock('react-chartjs-2', () => ({
    Line: ({ data }) => <div data-testid="line-chart" data-datasets={data.datasets.map((d) => d.label).join(',')} />,
}));

global.route = (name) => `/${name}`;

const instances = [
    { port: 6379, label: 'Main' },
    { port: 6381, label: 'Cache' },
];

const payload = (over = {}) => ({
    port: 6379,
    data: {
        window: '1d',
        bucket: 300,
        series: [
            { t: 1700000000, ops: 10, mem: 100, max: 1000, rx: 3000, tx: 6000, hits: 1, miss: 1, keys: 5, cli: 2 },
            { t: 1700000300, ops: 20, mem: 200, max: 1000, rx: 3000, tx: 6000, hits: 1, miss: 1, keys: 6, cli: 3 },
        ],
        summary: {
            samples: 2, opsAvg: 15, opsPeak: 20, hits: 2, miss: 2, hitRate: 0.5, rx: 6000, tx: 12000, bytes: 18000,
            memNow: 200, maxNow: 1000, memPct: 0.2, keysNow: 6, cliNow: 3, blockedNow: 0, evictedNow: 0,
            version: '8.0.2', uptimeSec: 90000, restarts: 0, ageSec: 10, stale: false,
        },
        dbs: { 0: 5, 10: 1 },
        topCommands: [{ cmd: 'get', calls: 900, rate: 12.5, share: 0.6 }],
    },
    status: { at: 1700000300, ok: true, added: 4, error: null },
    alerts: [],
    now: 1700000310,
    ...over,
});

const props = (over = {}) => ({ enabled: true, instances, status: null, alerts: [], now: 1700000310, ...over });

beforeEach(() => {
    global.fetch = vi.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve(payload()) }));
});
afterEach(() => vi.restoreAllMocks());

test('format helpers: bytes, rates, percentages, uptime and the storage pill lines', () => {
    expect(fmtBytes(1536)).toBe('1.5 KB');
    expect(fmtBytes(null)).toBe('-');
    expect(fmtRate(0.456)).toBe('0.46');
    expect(fmtPct(0.2, 1)).toBe('20.0%');
    expect(fmtUptime(90000)).toBe('1d 1h');
    expect(memLevel(0.74)).toBe('ok');
    expect(memLevel(0.75)).toBe('amber');
    expect(memLevel(0.9)).toBe('red');
    expect(memLevel(null)).toBe('none');
});

test('disabled monitor shows how to turn it on and never fetches', () => {
    render(<RedisIndex {...props({ enabled: false })} />);
    expect(screen.getByTestId('redis-disabled')).toHaveTextContent('REDIS_MONITOR_ENABLED');
    expect(global.fetch).not.toHaveBeenCalled();
});

test('shows memory, ops, bandwidth, keys, clients, top commands and keys per db for the first instance', async () => {
    render(<RedisIndex {...props()} />);
    await waitFor(() => expect(screen.getByTestId('stat-memory')).toBeInTheDocument());
    expect(screen.getByTestId('stat-memory')).toHaveTextContent('200 B');
    expect(screen.getByTestId('stat-memory')).toHaveTextContent('20.0% of 1000 B');
    expect(screen.getByTestId('stat-ops')).toHaveTextContent('15.0');
    expect(screen.getByTestId('stat-bandwidth')).toHaveTextContent('in 5.9 KB');
    expect(screen.getByTestId('stat-clients')).toHaveTextContent('3');
    expect(screen.getByTestId('top-commands')).toHaveTextContent('get');
    expect(screen.getByTestId('keys-per-db')).toHaveTextContent('db10');
    expect(screen.getAllByTestId('line-chart')).toHaveLength(6);
    expect(global.fetch.mock.calls[0][0]).toContain('port=6379&window=1d');
    expect(screen.getByTestId('redis-memory-pill')).toHaveTextContent('storage 20.0%');
});

test('switching instance and window refetches with the new port and window', async () => {
    render(<RedisIndex {...props()} />);
    await waitFor(() => screen.getByTestId('stat-memory'));
    fireEvent.click(screen.getByRole('tab', { name: /Cache/ }));
    await waitFor(() => expect(global.fetch.mock.calls.some((c) => c[0].includes('port=6381'))).toBe(true));
    fireEvent.click(screen.getByRole('button', { name: 'Live' }));
    await waitFor(() => expect(global.fetch.mock.calls.some((c) => c[0].includes('port=6381&window=live'))).toBe(true));
});

test('storage alert banner and red pill at 90 percent', async () => {
    const p = payload({ alerts: [{ id: 'a', port: 6379, threshold: 90, pct: 91.2, at: 1700000000 }] });
    p.data.summary.memPct = 0.912;
    global.fetch = vi.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve(p) }));
    render(<RedisIndex {...props()} />);
    await waitFor(() => screen.getByTestId('redis-alerts'));
    expect(screen.getByTestId('redis-alerts')).toHaveTextContent('Storage 90%: Main reached 91.2%');
    expect(screen.getByTestId('redis-memory-pill').className).toContain('red');
});

test('a window with no samples says so instead of drawing empty charts', async () => {
    const p = payload();
    p.data.summary.samples = 0;
    global.fetch = vi.fn(() => Promise.resolve({ ok: true, json: () => Promise.resolve(p) }));
    render(<RedisIndex {...props()} />);
    await waitFor(() => screen.getByTestId('redis-empty'));
    expect(screen.queryAllByTestId('line-chart')).toHaveLength(0);
});

test('a failed history pull and a failed refresh are both shown, not hidden', async () => {
    global.fetch = vi.fn(() => Promise.resolve({ ok: false, status: 500, json: () => Promise.resolve({}) }));
    render(<RedisIndex {...props({ status: { at: 1700000000, ok: false, added: 0, error: 'Host key verification failed.' } })} />);
    await waitFor(() => expect(screen.getByTestId('redis-status')).toHaveTextContent('HTTP 500'));
    expect(screen.getByTestId('redis-status')).toHaveTextContent('Host key verification failed.');
});
