<?php

/**
 * The panel's own DB (pending approvals, sessions, queue) must never sleep.
 * If the hosting DB engine IS the panel DB instance, sleep must be refused.
 */

use App\Services\Sleep\PanelDatabaseGuard;

// These tests re-point the panel DB connection; restore it so RefreshDatabase can roll back.
beforeEach(function () {
    $this->origDbDefault = config('database.default');
    $this->origDbConnections = config('database.connections');
});
afterEach(function () {
    config(['database.default' => $this->origDbDefault, 'database.connections' => $this->origDbConnections]);
});

function guardFor(array $conn, string $default = 'mysql'): PanelDatabaseGuard
{
    config(['database.default' => $default, "database.connections.{$default}" => $conn]);

    return new PanelDatabaseGuard;
}

function mysqlEntry(): array
{
    return ['kind' => 'db', 'engine' => 'mysql', 'unit' => 'mysql.service', 'public_port' => '3306', 'public_socket' => '/var/run/mysqld/mysqld.sock'];
}

test('sqlite panel DB never shares an instance', function () {
    $g = guardFor(['driver' => 'sqlite', 'database' => ':memory:'], 'sqlite');
    expect($g->sharesInstance(mysqlEntry()))->toBeFalse();
});

test('panel on local mysql 127.0.0.1:3306 shares the hosting mysql instance', function () {
    $g = guardFor(['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => '3306']);
    expect($g->sharesInstance(mysqlEntry()))->toBeTrue();
});

test('panel on localhost with no port (default 3306) shares', function () {
    $g = guardFor(['driver' => 'mysql', 'host' => 'localhost']);
    expect($g->sharesInstance(mysqlEntry()))->toBeTrue();
});

test('panel connected over the same unix socket shares', function () {
    $g = guardFor(['driver' => 'mysql', 'host' => '10.9.9.9', 'port' => '3306', 'unix_socket' => '/var/run/mysqld/mysqld.sock']);
    expect($g->sharesInstance(mysqlEntry()))->toBeTrue();
});

test('mariadb driver counts as the same family as a mysql-family engine', function () {
    $g = guardFor(['driver' => 'mariadb', 'host' => '127.0.0.1', 'port' => '3306'], 'mariadb');
    expect($g->sharesInstance(mysqlEntry()))->toBeTrue();
});

test('remote panel DB does not share', function () {
    $g = guardFor(['driver' => 'mysql', 'host' => 'db.internal.example', 'port' => '3306']);
    expect($g->sharesInstance(mysqlEntry()))->toBeFalse();
});

test('panel DB on another local port does not share', function () {
    $g = guardFor(['driver' => 'mysql', 'host' => '127.0.0.1', 'port' => '3399']);
    expect($g->sharesInstance(mysqlEntry()))->toBeFalse();
});

test('pgsql panel DB is not the mysql hosting engine', function () {
    $g = guardFor(['driver' => 'pgsql', 'host' => '127.0.0.1', 'port' => '5432'], 'pgsql');
    expect($g->sharesInstance(mysqlEntry()))->toBeFalse();
});
