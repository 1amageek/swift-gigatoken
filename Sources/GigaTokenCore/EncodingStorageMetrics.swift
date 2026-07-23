public struct EncodingStorageMetrics: Equatable, Sendable {
  public let shortCacheEntryCount: Int
  public let shortCacheSlotCapacity: Int
  public let shortCacheAddressModulo64: Int
  public let shortCacheAddressModuloTwoMiB: Int
  public let longCacheEntryCount: Int
  public let longCacheSlotCapacity: Int
  public let longCacheStoredByteCount: Int
  public let tokenArenaCount: Int
  public let tokenArenaCapacity: Int
  public let mergeSymbolCount: Int
  public let mergeSymbolCapacity: Int
  public let mergeLinkCapacity: Int

  public init(
    shortCacheEntryCount: Int,
    shortCacheSlotCapacity: Int,
    shortCacheAddressModulo64: Int,
    shortCacheAddressModuloTwoMiB: Int,
    longCacheEntryCount: Int,
    longCacheSlotCapacity: Int,
    longCacheStoredByteCount: Int,
    tokenArenaCount: Int,
    tokenArenaCapacity: Int,
    mergeSymbolCount: Int,
    mergeSymbolCapacity: Int,
    mergeLinkCapacity: Int
  ) {
    self.shortCacheEntryCount = shortCacheEntryCount
    self.shortCacheSlotCapacity = shortCacheSlotCapacity
    self.shortCacheAddressModulo64 = shortCacheAddressModulo64
    self.shortCacheAddressModuloTwoMiB = shortCacheAddressModuloTwoMiB
    self.longCacheEntryCount = longCacheEntryCount
    self.longCacheSlotCapacity = longCacheSlotCapacity
    self.longCacheStoredByteCount = longCacheStoredByteCount
    self.tokenArenaCount = tokenArenaCount
    self.tokenArenaCapacity = tokenArenaCapacity
    self.mergeSymbolCount = mergeSymbolCount
    self.mergeSymbolCapacity = mergeSymbolCapacity
    self.mergeLinkCapacity = mergeLinkCapacity
  }
}
