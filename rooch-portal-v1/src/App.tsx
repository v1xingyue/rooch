import { CacheProvider } from '@emotion/react'
import { ThemeProvider } from '@/components/theme-provider'

import { createEmotionCache } from '@/utils/create-emotion-cache'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

import { TESTNetwork } from '@roochnetwork/rooch-sdk'
import { WalletProvider, RoochClientProvider, SupportChain } from '@roochnetwork/rooch-sdk-kit'

import { DashboardLayout } from './(dashboard)/dashboard-layout'

const clientSideEmotionCache = createEmotionCache()

function App() {
  const queryClient = new QueryClient()

  return (
    <>
      <CacheProvider value={clientSideEmotionCache}>
        <QueryClientProvider client={queryClient}>
          <RoochClientProvider defaultNetwork={TESTNetwork}>
            <WalletProvider chain={SupportChain.BITCOIN}>
              <ThemeProvider defaultTheme="system" storageKey="vite-ui-theme">
                <DashboardLayout />
              </ThemeProvider>
            </WalletProvider>
          </RoochClientProvider>
        </QueryClientProvider>
      </CacheProvider>
    </>
  )
}

export default App
