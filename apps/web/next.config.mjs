/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Пакеты воркспейса поставляются как TypeScript-исходники
  transpilePackages: ['@logocrm/core', '@logocrm/contracts', '@logocrm/db'],
}

export default nextConfig
