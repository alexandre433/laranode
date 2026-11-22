<?php

use App\Http\Requests\CreateWebsiteRequest;
use Illuminate\Support\Facades\Validator;

// The sudo'd scripts accept a document root only of the shape ln_docroot allows
// (^/[A-Za-z0-9._/-]*$, no ".." segment). The FormRequest must refuse everything else up
// front, otherwise the script refuses later and the failure surfaces obscurely.
function documentRootErrors(string $value): array
{
    $rules = (new CreateWebsiteRequest)->rules()['document_root'];

    return Validator::make(['document_root' => $value], ['document_root' => $rules])->errors()->get('document_root');
}

test('document_root accepts what the privileged scripts accept', function (string $value) {
    expect(documentRootErrors($value))->toBe([]);
})->with(['/', '/public', '/public/web', '/app.v2/public_html', '/a-b/c_d']);

test('document_root refuses what the privileged scripts would refuse', function (string $value) {
    expect(documentRootErrors($value))->not->toBe([]);
})->with([
    'no leading slash' => 'public',
    'space' => '/my site',
    'parent segment' => '/../etc',
    'embedded parent segment' => '/a/../b',
    'semicolon' => '/a;id',
    'newline' => "/a\nb",
    'trailing newline' => "/public\n",
    'dollar' => '/$(id)',
    'quote' => '/a"b',
]);
