// Copyright (c) 2020 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.resources

import scala.concurrent.{ExecutionContext, Future}

class CloseableResourceOwner[T <: AutoCloseable](acquireCloseable: () => T)
    extends ResourceOwner[T] {
  override def acquire()(implicit executionContext: ExecutionContext): Resource[T] =
    Resource(Future(acquireCloseable()), closeable => Future(closeable.close()))
}
