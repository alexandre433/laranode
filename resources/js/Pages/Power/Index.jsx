import AuthenticatedLayout from '@/Layouts/AuthenticatedLayout';
import { Head } from '@inertiajs/react';
import axios from 'axios';
import { useCallback, useEffect, useRef, useState } from 'react';

const STATE_BADGE = {
    running: 'bg-green-200 text-green-800 dark:bg-green-800 dark:text-green-200',
    sleeping: 'bg-indigo-200 text-indigo-800 dark:bg-indigo-800 dark:text-indigo-200',
    ondemand: 'bg-indigo-200 text-indigo-800 dark:bg-indigo-800 dark:text-indigo-200',
    stopped: 'bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-200',
    external: 'bg-yellow-200 text-yellow-800 dark:bg-yellow-800 dark:text-yellow-200',
};

const REASON_TEXT = {
    panel_db: 'cannot sleep: panel DB',
    apparmor: 'cannot sleep: AppArmor profile blocks the moved DB socket',
    unsupported_engine: 'cannot sleep: only MySQL/MariaDB can sleep',
    external: 'external service, never managed by Laranode',
};

const POLL_MS = 5000;

export default function Index() {
    const [services, setServices] = useState(null);
    const [external, setExternal] = useState([]);
    const [idle, setIdle] = useState({});
    const [busy, setBusy] = useState(null);
    const [error, setError] = useState(null);
    const idleTouched = useRef({});

    const load = useCallback(async () => {
        try {
            const { data } = await axios.get(route('power.status'));
            setServices(data.services);
            setExternal(data.external ?? []);
            setIdle((prev) => {
                const next = { ...prev };
                data.services.forEach((s) => {
                    if (!idleTouched.current[s.key]) {
                        next[s.key] = String(s.idle_minutes ?? s.default_idle_minutes ?? 10);
                    }
                });
                return next;
            });
        } catch (e) {
            setError(e?.response?.data?.message ?? 'Could not load power status.');
        }
    }, []);

    useEffect(() => {
        load();
        const t = setInterval(load, POLL_MS);
        return () => clearInterval(t);
    }, [load]);

    const send = async (payload) => {
        setError(null);
        setBusy(payload.key);
        try {
            await axios.post(route('power.action'), payload);
            await load();
        } catch (e) {
            setError(e?.response?.data?.message ?? 'Request failed.');
        } finally {
            setBusy(null);
        }
    };

    const toggle = (svc) => {
        if (svc.enabled) {
            return send({ key: svc.key, action: 'disable' });
        }
        if (!svc.supports_idle) {
            return send({ key: svc.key, action: 'enable' });
        }
        const raw = String(idle[svc.key] ?? '').trim();
        const n = Number(raw);
        if (!/^\d+$/.test(raw) || n < 1 || n > 1440) {
            setError('Idle minutes must be between 1 and 1440.');
            return;
        }
        return send({ key: svc.key, action: 'enable', idle_minutes: n });
    };

    return (
        <AuthenticatedLayout>
            <Head title="Power" />
            <div className="max-w-5xl px-4 my-8 dark:text-gray-100">
                <h1 className="text-xl font-semibold mb-1 dark:text-gray-100">Power</h1>
                <p className="text-sm text-gray-600 dark:text-gray-400 mb-4">
                    Optional. Sleep stops an idle service to free RAM and wakes it on the next connection. Off by default; only
                    services Laranode installed can sleep. SSH, Apache, the PHP-FPM master and the panel database never sleep.
                </p>

                {error && (
                    <div role="alert" className="mb-4 px-3 py-2 rounded bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100 text-sm">
                        {error}
                    </div>
                )}

                {services === null ? (
                    <p className="text-sm">Loading…</p>
                ) : (
                    <table className="w-full text-sm">
                        <thead>
                            <tr className="text-left border-b dark:text-gray-300 dark:border-gray-700">
                                <th className="py-2">Service</th>
                                <th>State</th>
                                <th>Sleep</th>
                                <th>Idle (min)</th>
                                <th>Manual</th>
                            </tr>
                        </thead>
                        <tbody>
                            {services.map((s) => {
                                const locked = !s.managed || !s.can_sleep;
                                return (
                                    <tr key={s.key} className="border-b align-top dark:border-gray-700 dark:text-gray-200">
                                        <td className="py-2">
                                            <div>{s.label}</div>
                                            {s.reason && (
                                                <div className="text-xs text-gray-500 dark:text-gray-400">{REASON_TEXT[s.reason] ?? s.reason}</div>
                                            )}
                                        </td>
                                        <td>
                                            <span data-testid={`state-${s.key}`} className={`px-2 py-1 rounded text-xs ${STATE_BADGE[s.state] ?? ''}`}>
                                                {s.state}
                                            </span>
                                        </td>
                                        <td>
                                            <input
                                                type="checkbox"
                                                aria-label={`sleep ${s.key}`}
                                                checked={!!s.enabled}
                                                disabled={locked || busy === s.key}
                                                onChange={() => toggle(s)}
                                            />
                                        </td>
                                        <td>
                                            {s.supports_idle && (
                                                <input
                                                    type="number"
                                                    min="1"
                                                    max="1440"
                                                    aria-label={`idle minutes for ${s.key}`}
                                                    className="w-20 px-2 py-1 border rounded dark:bg-gray-800 dark:border-gray-600"
                                                    value={idle[s.key] ?? ''}
                                                    disabled={locked || s.enabled}
                                                    onChange={(e) => {
                                                        idleTouched.current[s.key] = true;
                                                        setIdle((p) => ({ ...p, [s.key]: e.target.value }));
                                                    }}
                                                />
                                            )}
                                        </td>
                                        <td>
                                            {s.enabled && s.supports_manual && s.state === 'sleeping' && (
                                                <button
                                                    type="button"
                                                    aria-label={`wake ${s.key}`}
                                                    disabled={busy === s.key}
                                                    className="px-3 py-1 border rounded dark:border-gray-600"
                                                    onClick={() => send({ key: s.key, action: 'wake' })}
                                                >
                                                    Wake
                                                </button>
                                            )}
                                            {s.enabled && s.supports_manual && s.state === 'running' && (
                                                <button
                                                    type="button"
                                                    aria-label={`sleep ${s.key} now`}
                                                    disabled={busy === s.key}
                                                    className="px-3 py-1 border rounded dark:border-gray-600"
                                                    onClick={() => send({ key: s.key, action: 'sleep' })}
                                                >
                                                    Sleep now
                                                </button>
                                            )}
                                        </td>
                                    </tr>
                                );
                            })}
                        </tbody>
                    </table>
                )}

                {external.length > 0 && (
                    <div data-testid="external-list" className="mt-6 text-sm">
                        <h2 className="font-semibold mb-1">External services (never managed)</h2>
                        <ul className="list-disc ml-5 text-gray-700 dark:text-gray-300">
                            {external.map((e) => (
                                <li key={e.service}>{e.service}</li>
                            ))}
                        </ul>
                    </div>
                )}
            </div>
        </AuthenticatedLayout>
    );
}
