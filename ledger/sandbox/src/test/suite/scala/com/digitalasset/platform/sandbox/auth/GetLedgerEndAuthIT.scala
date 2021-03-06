// Copyright (c) 2020 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.platform.sandbox.auth

import com.digitalasset.ledger.api.v1.transaction_service.{
  GetLedgerEndRequest,
  TransactionServiceGrpc
}

import scala.concurrent.Future

final class GetLedgerEndAuthIT extends PublicServiceCallAuthTests {

  override def serviceCallName: String = "TransactionService#GetLedgerEnd"

  private lazy val request = new GetLedgerEndRequest(unwrappedLedgerId)

  override def serviceCallWithToken(token: Option[String]): Future[Any] =
    stub(TransactionServiceGrpc.stub(channel), token).getLedgerEnd(request)

}
