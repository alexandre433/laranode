import AuthenticatedLayout from '@/Layouts/AuthenticatedLayout';
import { Head, Link } from '@inertiajs/react';
import { useState } from 'react';

const badge = { queued: 'bg-gray-200 text-gray-800', running: 'bg-blue-200 text-blue-800', succeeded: 'bg-green-200 text-green-800', failed: 'bg-red-200 text-red-800' };

export default function Index({ operations }) {
    const [open, setOpen] = useState(null);
    return (
        <AuthenticatedLayout>
            <Head title="Operations" />
            <div className="p-6">
                <h1 className="text-xl font-semibold mb-4">Operations</h1>
                <table className="w-full text-sm">
                    <thead>
                        <tr className="text-left border-b">
                            <th className="py-2">When</th><th>Actor</th><th>Type</th><th>Target</th><th>Status</th>
                        </tr>
                    </thead>
                    <tbody>
                        {operations.data.map((op) => (
                            <tr key={op.id} className="border-b align-top cursor-pointer" onClick={() => setOpen(open === op.id ? null : op.id)}>
                                <td className="py-2">{op.created_at}</td>
                                <td>{op.user?.username ?? '—'}</td>
                                <td>{op.type}</td>
                                <td>{op.target ?? '—'}</td>
                                <td><span className={`px-2 py-1 rounded text-xs ${badge[op.status] ?? ''}`}>{op.status}</span>
                                    {open === op.id && (
                                        <pre className="mt-2 whitespace-pre-wrap bg-black text-green-300 p-2 rounded max-h-64 overflow-auto">{op.output ?? '(no output)'}</pre>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
                <div className="mt-4 flex items-center gap-2">
                    {operations.prev_page_url
                        ? <Link href={operations.prev_page_url} className="px-3 py-1 border rounded" preserveScroll>Previous</Link>
                        : <span className="px-3 py-1 border rounded opacity-50">Previous</span>}
                    <span className="text-sm">Page {operations.current_page} of {operations.last_page}</span>
                    {operations.next_page_url
                        ? <Link href={operations.next_page_url} className="px-3 py-1 border rounded" preserveScroll>Next</Link>
                        : <span className="px-3 py-1 border rounded opacity-50">Next</span>}
                </div>
            </div>
        </AuthenticatedLayout>
    );
}
