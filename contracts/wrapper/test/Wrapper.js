/* global artifacts, contract */
const Swap = artifacts.require('Swap')
const Transfers = artifacts.require('Transfers')
const Types = artifacts.require('Types')
const Wrapper = artifacts.require('Wrapper')
const WETH9 = artifacts.require('WETH9')
const FungibleToken = artifacts.require('FungibleToken')

const { emitted, getResult, passes, ok } = require('@airswap/test-utils').assert
const { balances } = require('@airswap/test-utils').balances
const {
  getTimestampPlusDays,
  takeSnapshot,
  revertToSnapShot,
} = require('@airswap/test-utils').time
const { orders, signatures } = require('@airswap/order-utils')

let swapContract
let wrapperContract

let swapAddress
let wrapperAddress

let swapSimple

let tokenDAI
let tokenWETH
let snapshotId

contract('Wrapper', async ([aliceAddress, bobAddress, carolAddress]) => {
  orders.setKnownAccounts([aliceAddress, bobAddress, carolAddress])

  before('Setup', async () => {
    let snapShot = await takeSnapshot()
    snapshotId = snapShot['result']
    // deploy both libs
    const transfersLib = await Transfers.new()
    const typesLib = await Types.new()

    // link both libs to swap
    await Swap.link(Transfers, transfersLib.address)
    await Swap.link(Types, typesLib.address)

    // now deploy swap
    swapContract = await Swap.new()

    swapAddress = swapContract.address
    tokenWETH = await WETH9.new()
    wrapperContract = await Wrapper.new(swapAddress, tokenWETH.address)
    wrapperAddress = wrapperContract.address
    tokenDAI = await FungibleToken.new()

    await orders.setVerifyingContract(swapAddress)

    swapSimple =
      wrapperContract.methods[
        'swapSimple(uint256,uint256,address,uint256,address,address,uint256,address,uint8,bytes32,bytes32)'
      ]
  })

  after(async () => {
    await revertToSnapShot(snapshotId)
  })

  describe('Setup', async () => {
    it('Mints 1000 DAI for Alice', async () => {
      let tx = await tokenDAI.mint(aliceAddress, 1000)
      ok(await balances(aliceAddress, [[tokenDAI, 1000]]))
      emitted(tx, 'Transfer')
      passes(tx)
    })
  })

  describe('Approving...', async () => {
    it('Alice approves Swap to spend 9999 DAI', async () => {
      let result = await tokenDAI.approve(swapAddress, 1000, {
        from: aliceAddress,
      })
      emitted(result, 'Approval')
    })
  })

  describe('Wrap Buys', async () => {
    it('Checks that Bob take a WETH order from Alice using ETH', async () => {
      const { order } = await orders.getOrder({
        maker: {
          wallet: aliceAddress,
          token: tokenDAI.address,
          param: 50,
        },
        taker: {
          token: tokenWETH.address,
          param: 10,
        },
      })
      const signature = await signatures.getSimpleSignature(
        order,
        aliceAddress,
        swapAddress
      )
      let result = await swapSimple(
        order.nonce,
        order.expiry,
        order.maker.wallet,
        order.maker.param,
        order.maker.token,
        order.taker.wallet,
        order.taker.param,
        order.taker.token,
        signature.v,
        signature.r,
        signature.s,
        { from: bobAddress, value: order.taker.param }
      )
      await passes(result)
      result = await getResult(swapContract, result.tx)
      emitted(result, 'Swap')
    })
  })

  describe('Unwrap Sells', async () => {
    it('Carol gets some WETH and approves on the Swap contract', async () => {
      let tx = await tokenWETH.deposit({ from: carolAddress, value: 10000 })
      passes(tx)
      emitted(tx, 'Deposit')
      tx = await tokenWETH.approve(swapAddress, 10000, { from: carolAddress })
      passes(tx)
      emitted(tx, 'Approval')
    })

    it('Alice authorizes the Wrapper to send orders on her behalf', async () => {
      let expiry = await getTimestampPlusDays(1)
      let tx = await swapContract.authorize(wrapperAddress, expiry, {
        from: aliceAddress,
      })
      passes(tx)
      emitted(tx, 'Authorize')
    })

    it('Alice authorizes the Swap contract to move her WETH', async () => {
      let tx = await tokenWETH.approve(wrapperAddress, 10000, {
        from: aliceAddress,
      })
      passes(tx)
      emitted(tx, 'Approval')
    })

    it('Checks that Alice receives ETH for a WETH order from Carol', async () => {
      const { order } = await orders.getOrder({
        maker: {
          wallet: carolAddress,
          token: tokenWETH.address,
          param: 10000,
        },
        taker: {
          wallet: aliceAddress,
          token: tokenDAI.address,
          param: 100,
        },
      })
      const signature = await signatures.getSimpleSignature(
        order,
        carolAddress,
        swapAddress
      )

      let result = await swapSimple(
        order.nonce,
        order.expiry,
        order.maker.wallet,
        order.maker.param,
        order.maker.token,
        order.taker.wallet,
        order.taker.param,
        order.taker.token,
        signature.v,
        signature.r,
        signature.s,
        { from: aliceAddress }
      )
      passes(result)
      result = await getResult(swapContract, result.tx)
      emitted(result, 'Swap')
    })
  })
})
