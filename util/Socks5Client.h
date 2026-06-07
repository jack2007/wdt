/**
 * Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
#pragma once

#include <wdt/AbortChecker.h>
#include <wdt/ErrorCodes.h>

#include <string>

namespace facebook {
namespace wdt {

struct Socks5Endpoint {
  std::string host;
  int port{0};
};

struct Socks5Auth {
  std::string user;
  std::string password;
};

/**
 * Parse "host:port" or "[ipv6]:port" into host and port.
 */
bool parseSocks5Proxy(const std::string& spec, Socks5Endpoint& out);

/**
 * Parse "user:password" (password may contain ':').
 * Returns false if spec is empty or user is empty.
 */
bool parseSocks5Auth(const std::string& spec, Socks5Auth& out);

/**
 * Perform SOCKS5 handshake and CONNECT on an already-established TCP fd to
 * proxyHost:proxyPort. auth is nullptr for no-auth method.
 */
ErrorCode socks5ConnectThrough(
    int fd,
    const std::string& destHost,
    int destPort,
    const Socks5Auth* auth,
    int connectTimeoutMillis,
    int abortCheckIntervalMillis,
    IAbortChecker const* abortChecker);

}  // namespace wdt
}  // namespace facebook
