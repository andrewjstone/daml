// Copyright (c) 2020 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.daml.ledger.on.sql.queries

import java.sql.Connection

import anorm.SqlParser._
import anorm._
import com.daml.ledger.on.sql.Index
import com.daml.ledger.on.sql.queries.Queries._
import com.daml.ledger.participant.state.kvutils.DamlKvutils.DamlLogEntryId
import com.google.protobuf.ByteString

class H2Queries extends Queries with CommonQueries {
  override def insertIntoLog(
      entry: DamlLogEntryId,
      envelope: ByteString,
  )(implicit connection: Connection): Index = {
    val entryIdStream = entry.getEntryId.newInput()
    val envelopeStream = envelope.newInput()
    SQL"INSERT INTO #$LogTable (entry_id, envelope) VALUES ($entryIdStream, $envelopeStream)"
      .executeInsert()
    SQL"CALL IDENTITY()"
      .as(long("IDENTITY()").single)
  }

  override protected val updateStateQuery: String =
    s"MERGE INTO $StateTable VALUES ({key}, {value})"
}
