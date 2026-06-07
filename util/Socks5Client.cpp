/**
 * Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
#include <wdt/util/Socks5Client.h>

#include <fcntl.h>
#include <folly/Conv.h>
#include <glog/logging.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <wdt/Reporting.h>

#include <cstring>
#include <vector>

namespace facebook {
namespace wdt {

namespace {

constexpr uint8_t kSocksVersion = 0x05;
constexpr uint8_t kCmdConnect = 0x01;
constexpr uint8_t kAtypDomain = 0x03;
constexpr uint8_t kAuthMethodNone = 0x00;
constexpr uint8_t kAuthMethodUserPass = 0x02;
constexpr uint8_t kAuthVersion = 0x01;

ErrorCode readFully(int fd, char* buf, size_t len, int timeoutMillis,
                    int abortCheckIntervalMillis,
                    IAbortChecker const* abortChecker) {
  size_t off = 0;
  auto startTime = Clock::now();
  while (off < len) {
    if (abortChecker != nullptr && abortChecker->shouldAbort()) {
      return ABORT;
    }
    int timeElapsed = durationMillis(Clock::now() - startTime);
    if (timeElapsed >= timeoutMillis) {
      WLOG(ERROR) << "SOCKS5 read timed out";
      return CONN_ERROR_RETRYABLE;
    }
    int pollTimeout =
        std::min(timeoutMillis - timeElapsed, abortCheckIntervalMillis);
    struct pollfd pollFds[] = {{fd, POLLIN, 0}};
    int res = poll(pollFds, 1, pollTimeout);
    if (res <= 0) {
      if (res == 0 || errno == EINTR) {
        continue;
      }
      WPLOG(ERROR) << "SOCKS5 poll(read) failed";
      return CONN_ERROR;
    }
    ssize_t n = ::read(fd, buf + off, len - off);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      WPLOG(ERROR) << "SOCKS5 read failed";
      return CONN_ERROR;
    }
    if (n == 0) {
      WLOG(ERROR) << "SOCKS5 unexpected EOF while reading";
      return CONN_ERROR;
    }
    off += static_cast<size_t>(n);
  }
  return OK;
}

ErrorCode writeFully(int fd, const char* buf, size_t len, int timeoutMillis,
                     int abortCheckIntervalMillis,
                     IAbortChecker const* abortChecker) {
  size_t off = 0;
  auto startTime = Clock::now();
  while (off < len) {
    if (abortChecker != nullptr && abortChecker->shouldAbort()) {
      return ABORT;
    }
    int timeElapsed = durationMillis(Clock::now() - startTime);
    if (timeElapsed >= timeoutMillis) {
      WLOG(ERROR) << "SOCKS5 write timed out";
      return CONN_ERROR_RETRYABLE;
    }
    int pollTimeout =
        std::min(timeoutMillis - timeElapsed, abortCheckIntervalMillis);
    struct pollfd pollFds[] = {{fd, POLLOUT, 0}};
    int res = poll(pollFds, 1, pollTimeout);
    if (res <= 0) {
      if (res == 0 || errno == EINTR) {
        continue;
      }
      WPLOG(ERROR) << "SOCKS5 poll(write) failed";
      return CONN_ERROR;
    }
    ssize_t n = ::write(fd, buf + off, len - off);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      WPLOG(ERROR) << "SOCKS5 write failed";
      return CONN_ERROR;
    }
    if (n == 0) {
      WLOG(ERROR) << "SOCKS5 write returned 0";
      return CONN_ERROR;
    }
    off += static_cast<size_t>(n);
  }
  return OK;
}

ErrorCode skipSocks5BindAddress(int fd, uint8_t atyp, int timeoutMillis,
                                int abortCheckIntervalMillis,
                                IAbortChecker const* abortChecker) {
  size_t addrLen = 0;
  if (atyp == 0x01) {
    addrLen = 4;
  } else if (atyp == 0x04) {
    addrLen = 16;
  } else if (atyp == 0x03) {
    char lenBuf[1];
    ErrorCode code = readFully(fd, lenBuf, 1, timeoutMillis,
                               abortCheckIntervalMillis, abortChecker);
    if (code != OK) {
      return code;
    }
    addrLen = static_cast<uint8_t>(lenBuf[0]);
  } else {
    WLOG(ERROR) << "SOCKS5 reply has unsupported address type " << int(atyp);
    return CONN_ERROR;
  }
  std::vector<char> skipBuf(addrLen + 2);
  return readFully(fd, skipBuf.data(), skipBuf.size(), timeoutMillis,
                   abortCheckIntervalMillis, abortChecker);
}

}  // namespace

bool parseSocks5Proxy(const std::string& spec, Socks5Endpoint& out) {
  out = Socks5Endpoint{};
  if (spec.empty()) {
    return false;
  }
  std::string host;
  std::string portStr;
  if (spec.front() == '[') {
    const auto endBracket = spec.find("]:");
    if (endBracket == std::string::npos || endBracket <= 1) {
      return false;
    }
    host = spec.substr(1, endBracket - 1);
    portStr = spec.substr(endBracket + 2);
  } else {
    const auto colon = spec.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= spec.size()) {
      return false;
    }
    host = spec.substr(0, colon);
    portStr = spec.substr(colon + 1);
  }
  if (host.empty() || portStr.empty()) {
    return false;
  }
  int port = 0;
  try {
    port = folly::to<int>(portStr);
  } catch (...) {
    return false;
  }
  if (port <= 0 || port > 65535) {
    return false;
  }
  out.host = host;
  out.port = port;
  return true;
}

bool parseSocks5Auth(const std::string& spec, Socks5Auth& out) {
  out = Socks5Auth{};
  if (spec.empty()) {
    return false;
  }
  const auto colon = spec.find(':');
  if (colon == std::string::npos) {
    return false;
  }
  out.user = spec.substr(0, colon);
  out.password = spec.substr(colon + 1);
  return !out.user.empty();
}

ErrorCode socks5ConnectThrough(
    int fd, const std::string& destHost, int destPort, const Socks5Auth* auth,
    int connectTimeoutMillis, int abortCheckIntervalMillis,
    IAbortChecker const* abortChecker) {
  if (destHost.empty() || destPort <= 0 || destPort > 65535) {
    WLOG(ERROR) << "Invalid SOCKS5 destination " << destHost << ":" << destPort;
    return CONN_ERROR;
  }
  if (destHost.size() > 255) {
    WLOG(ERROR) << "SOCKS5 destination hostname too long";
    return CONN_ERROR;
  }

  const uint8_t greeting[] = {kSocksVersion, 0x01,
                              auth != nullptr ? kAuthMethodUserPass
                                              : kAuthMethodNone};
  ErrorCode code = writeFully(fd, reinterpret_cast<const char*>(greeting),
                              sizeof(greeting), connectTimeoutMillis,
                              abortCheckIntervalMillis, abortChecker);
  if (code != OK) {
    return code;
  }

  char methodReply[2];
  code = readFully(fd, methodReply, sizeof(methodReply), connectTimeoutMillis,
                   abortCheckIntervalMillis, abortChecker);
  if (code != OK) {
    return code;
  }
  if (methodReply[0] != kSocksVersion) {
    WLOG(ERROR) << "SOCKS5 method reply bad version " << int(methodReply[0]);
    return CONN_ERROR;
  }
  const uint8_t selectedMethod = static_cast<uint8_t>(methodReply[1]);
  if (auth != nullptr) {
    if (selectedMethod != kAuthMethodUserPass) {
      WLOG(ERROR) << "SOCKS5 proxy rejected username/password auth";
      return CONN_ERROR;
    }
    if (auth->user.size() > 255 || auth->password.size() > 255) {
      WLOG(ERROR) << "SOCKS5 auth credentials too long";
      return CONN_ERROR;
    }
    std::vector<uint8_t> authReq;
    authReq.reserve(3 + auth->user.size() + auth->password.size());
    authReq.push_back(kAuthVersion);
    authReq.push_back(static_cast<uint8_t>(auth->user.size()));
    authReq.insert(authReq.end(), auth->user.begin(), auth->user.end());
    authReq.push_back(static_cast<uint8_t>(auth->password.size()));
    authReq.insert(authReq.end(), auth->password.begin(),
                   auth->password.end());
    code = writeFully(fd, reinterpret_cast<const char*>(authReq.data()),
                      authReq.size(), connectTimeoutMillis,
                      abortCheckIntervalMillis, abortChecker);
    if (code != OK) {
      return code;
    }
    char authReply[2];
    code = readFully(fd, authReply, sizeof(authReply), connectTimeoutMillis,
                     abortCheckIntervalMillis, abortChecker);
    if (code != OK) {
      return code;
    }
    if (authReply[0] != kAuthVersion || authReply[1] != 0x00) {
      WLOG(ERROR) << "SOCKS5 username/password authentication failed";
      return CONN_ERROR;
    }
  } else if (selectedMethod != kAuthMethodNone) {
    WLOG(ERROR) << "SOCKS5 proxy selected unsupported auth method "
                << int(selectedMethod);
    return CONN_ERROR;
  }

  std::vector<uint8_t> connectReq;
  connectReq.reserve(7 + destHost.size());
  connectReq.push_back(kSocksVersion);
  connectReq.push_back(kCmdConnect);
  connectReq.push_back(0x00);
  connectReq.push_back(kAtypDomain);
  connectReq.push_back(static_cast<uint8_t>(destHost.size()));
  connectReq.insert(connectReq.end(), destHost.begin(), destHost.end());
  connectReq.push_back(static_cast<uint8_t>((destPort >> 8) & 0xff));
  connectReq.push_back(static_cast<uint8_t>(destPort & 0xff));
  code = writeFully(fd, reinterpret_cast<const char*>(connectReq.data()),
                    connectReq.size(), connectTimeoutMillis,
                    abortCheckIntervalMillis, abortChecker);
  if (code != OK) {
    return code;
  }

  char connectReply[4];
  code = readFully(fd, connectReply, sizeof(connectReply),
                   connectTimeoutMillis, abortCheckIntervalMillis,
                   abortChecker);
  if (code != OK) {
    return code;
  }
  if (connectReply[0] != kSocksVersion) {
    WLOG(ERROR) << "SOCKS5 connect reply bad version " << int(connectReply[0]);
    return CONN_ERROR;
  }
  if (connectReply[1] != 0x00) {
    WLOG(ERROR) << "SOCKS5 CONNECT failed with reply code "
                << int(connectReply[1]);
    return CONN_ERROR;
  }
  return skipSocks5BindAddress(
      fd, static_cast<uint8_t>(connectReply[3]), connectTimeoutMillis,
      abortCheckIntervalMillis, abortChecker);
}

}  // namespace wdt
}  // namespace facebook
