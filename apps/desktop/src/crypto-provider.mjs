export function desktopCryptoProvider({qa,platform,safeStorage}) {
  // Disposable QA packages must never ask for access to the user's OS vault.
  // Linux remains unavailable until provider strength is qualified separately.
  if(qa || platform==='linux')return{
    available:async()=>false,
    encrypt:async()=>{throw new Error('Secure storage unavailable');},
    decrypt:async()=>{throw new Error('Secure storage unavailable');}
  };
  return{
    available:()=>safeStorage.isAsyncEncryptionAvailable(),
    encrypt:value=>safeStorage.encryptStringAsync(value),
    decrypt:async value=>(await safeStorage.decryptStringAsync(value)).result
  };
}
