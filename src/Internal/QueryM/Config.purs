module Ctl.Internal.QueryM.Config
  ( testnetTraceQueryConfig
  , testnetQueryConfig
  ) where

import Ctl.Internal.QueryM (QueryConfig)
import Ctl.Internal.QueryM.ServerConfig
  ( defaultKupoServerConfig
  , defaultOgmiosWsConfig
  )
import Ctl.Internal.Serialization.Address (NetworkId(TestnetId))
import Data.Log.Level (LogLevel(Error, Trace))
import Data.Maybe (Maybe(Nothing))

testnetTraceQueryConfig :: QueryConfig
testnetTraceQueryConfig =
  { ogmiosConfig: defaultOgmiosWsConfig
  , kupoConfig: defaultKupoServerConfig
  , networkId: TestnetId
  , logLevel: Trace
  , walletSpec: Nothing
  , customLogger: Nothing
  , suppressLogs: false
  }

testnetQueryConfig :: QueryConfig
testnetQueryConfig = testnetTraceQueryConfig { logLevel = Error }
