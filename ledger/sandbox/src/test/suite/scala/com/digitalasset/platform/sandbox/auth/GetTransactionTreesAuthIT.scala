// Copyright (c) 2020 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.platform.sandbox.auth

import com.digitalasset.ledger.api.v1.transaction_service.{
  GetTransactionTreesResponse,
  GetTransactionsRequest,
  TransactionServiceGrpc
}
import com.digitalasset.platform.sandbox.services.SubmitAndWaitDummyCommand
import io.grpc.stub.StreamObserver

final class GetTransactionTreesAuthIT
    extends ExpiringStreamServiceCallAuthTests[GetTransactionTreesResponse]
    with SubmitAndWaitDummyCommand {

  override def serviceCallName: String = "TransactionService#GetTransactionTrees"

  private lazy val request =
    new GetTransactionsRequest(unwrappedLedgerId, Option(ledgerBegin), None, txFilterFor(mainActor))

  override protected def stream
    : Option[String] => StreamObserver[GetTransactionTreesResponse] => Unit =
    token =>
      observer =>
        stub(TransactionServiceGrpc.stub(channel), token).getTransactionTrees(request, observer)

}
