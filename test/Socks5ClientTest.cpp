/**
 * Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
#include <gflags/gflags.h>
#include <glog/logging.h>
#include <gtest/gtest.h>
#include <wdt/util/Socks5Client.h>

namespace facebook {
namespace wdt {

TEST(Socks5Client, ParseProxyIpv4) {
  Socks5Endpoint endpoint;
  EXPECT_TRUE(parseSocks5Proxy("127.0.0.1:1080", endpoint));
  EXPECT_EQ("127.0.0.1", endpoint.host);
  EXPECT_EQ(1080, endpoint.port);
}

TEST(Socks5Client, ParseProxyHostname) {
  Socks5Endpoint endpoint;
  EXPECT_TRUE(parseSocks5Proxy("proxy.example.com:3128", endpoint));
  EXPECT_EQ("proxy.example.com", endpoint.host);
  EXPECT_EQ(3128, endpoint.port);
}

TEST(Socks5Client, ParseProxyIpv6) {
  Socks5Endpoint endpoint;
  EXPECT_TRUE(parseSocks5Proxy("[::1]:1080", endpoint));
  EXPECT_EQ("::1", endpoint.host);
  EXPECT_EQ(1080, endpoint.port);
}

TEST(Socks5Client, ParseProxyInvalid) {
  Socks5Endpoint endpoint;
  EXPECT_FALSE(parseSocks5Proxy("", endpoint));
  EXPECT_FALSE(parseSocks5Proxy("127.0.0.1", endpoint));
  EXPECT_FALSE(parseSocks5Proxy(":1080", endpoint));
  EXPECT_FALSE(parseSocks5Proxy("127.0.0.1:0", endpoint));
  EXPECT_FALSE(parseSocks5Proxy("[::1]", endpoint));
}

TEST(Socks5Client, ParseAuth) {
  Socks5Auth auth;
  EXPECT_TRUE(parseSocks5Auth("alice:secret", auth));
  EXPECT_EQ("alice", auth.user);
  EXPECT_EQ("secret", auth.password);
}

TEST(Socks5Client, ParseAuthPasswordWithColon) {
  Socks5Auth auth;
  EXPECT_TRUE(parseSocks5Auth("alice:sec:ret", auth));
  EXPECT_EQ("alice", auth.user);
  EXPECT_EQ("sec:ret", auth.password);
}

TEST(Socks5Client, ParseAuthInvalid) {
  Socks5Auth auth;
  EXPECT_FALSE(parseSocks5Auth("", auth));
  EXPECT_FALSE(parseSocks5Auth("alice", auth));
  EXPECT_FALSE(parseSocks5Auth(":password", auth));
}

}  // namespace wdt
}  // namespace facebook

int main(int argc, char* argv[]) {
  FLAGS_logtostderr = true;
  testing::InitGoogleTest(&argc, argv);
  GFLAGS_NAMESPACE::ParseCommandLineFlags(&argc, &argv, true);
  google::InitGoogleLogging(argv[0]);
  return RUN_ALL_TESTS();
}
