import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  allowedDevOrigins: ["10.0.2.2", "192.168.56.1"],
  turbopack: {
    root: __dirname,
  },
};

export default nextConfig;
