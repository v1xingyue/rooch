// Copyright (c) RoochNetwork
// SPDX-License-Identifier: Apache-2.0

import { WalletAccount } from '../WalletAccount'
import { BitcoinWallet } from './bitcoinWallet'
import { SupportChain } from '../../feature'
import { RoochClient } from '@roochnetwork/rooch-sdk'

export class OkxWallet extends BitcoinWallet {
  constructor(client: RoochClient) {
    super(client)
    this.name = 'okx'
  }

  async sign(msg: string): Promise<string> {
    return this.getTarget().signMessage(msg, {
      from: this.account?.address,
    })
  }

  getScheme(): number {
    return 2
  }

  getTarget(): any {
    return (window as any).okxwallet.bitcoin
  }

  async connect(): Promise<WalletAccount[]> {
    const account = await this.getTarget().connect()

    const walletAccount = new WalletAccount(
      this.client,
      SupportChain.BITCOIN,
      account?.address!,
      this,
      account.publicKey,
      account.compressedPublicKey,
    )

    this.account = walletAccount

    return [walletAccount]
  }

  switchNetwork(): void {
    this.getTarget().switchNetwork()
  }
  getNetwork(): string {
    return this.getTarget().getNetwork()
  }
  getSupportNetworks(): string[] {
    return ['livenet']
  }
  onAccountsChanged(callback: (account: WalletAccount[]) => void): void {
    this.getTarget().on('accountsChanged', callback)
  }
  removeAccountsChanged(callback: (account: WalletAccount[]) => void): void {
    this.getTarget().removeListener('accountsChanged', callback)
  }
  onNetworkChanged(callback: (network: string) => void): void {
    this.getTarget().on('networkChanged', callback)
  }
  removeNetworkChanged(callback: (network: string) => void): void {
    this.getTarget().removeListener('networkChanged', callback)
  }
}
