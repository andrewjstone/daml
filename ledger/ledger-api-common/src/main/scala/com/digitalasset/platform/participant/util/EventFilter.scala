// Copyright (c) 2020 The DAML Authors. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.platform.participant.util

import com.daml.ledger.participant.state.index.v2.AcsUpdateEvent
import com.digitalasset.daml.lf.data.Ref
import com.digitalasset.daml.lf.data.Ref.Party
import com.digitalasset.ledger.api.domain.Event.{ArchivedEvent, CreateOrArchiveEvent, CreatedEvent}
import com.digitalasset.ledger.api.domain.{InclusiveFilters, TransactionFilter}

import scala.collection.breakOut

object EventFilter {

  /**
    * Creates a filter which lets only such events through, where the template id is equal to the given one
    * and the interested party is affected.
    **/
  def byTemplates(transactionFilter: TransactionFilter): TemplateAwareFilter =
    TemplateAwareFilter(transactionFilter)

  @SuppressWarnings(Array("org.wartremover.warts.Any", "org.wartremover.warts.JavaSerializable"))
  final case class TemplateAwareFilter(transactionFilter: TransactionFilter) {

    def isSubmitterSubscriber(submitterParty: Party): Boolean =
      transactionFilter.filtersByParty.contains(submitterParty)

    lazy val (specificSubscriptions, globalSubscriptions) = {
      val specific = List.newBuilder[(Ref.Identifier, Party)]
      val global = Set.newBuilder[Party]
      for ((party, filters) <- transactionFilter.filtersByParty) {
        filters.inclusive match {
          case Some(InclusiveFilters(templateIds)) => specific ++= templateIds.map(_ -> party)
          case None => global += party
        }
      }
      (specific.result(), global.result())
    }

    lazy val subscribersByTemplateId: Map[Ref.Identifier, Set[Party]] = {
      specificSubscriptions
        .groupBy(_._1)
        .map { // Intentionally not using .mapValues to fully materialize the map
          case (templateId, pairs) =>
            val setOfParties: Set[Party] = pairs.map(_._2)(breakOut)
            templateId -> (setOfParties union globalSubscriptions)
        }
        .withDefaultValue(globalSubscriptions)
    }
  }

  def filterCreateOrArchiveWitnesses(
      filter: TemplateAwareFilter,
      event: CreateOrArchiveEvent): Option[CreateOrArchiveEvent] = {
    applyRequestingWitnesses[CreateOrArchiveEvent](
      filter,
      event,
      event.templateId,
      event.witnessParties) {
      case (ce: CreatedEvent, p) => ce.copy(witnessParties = p)
      case (ee: ArchivedEvent, p) => ee.copy(witnessParties = p)
    }
  }

  def filterActiveContractWitnesses(
      filter: TemplateAwareFilter,
      ac: AcsUpdateEvent.Create): Option[AcsUpdateEvent.Create] = {
    applyRequestingWitnesses(filter, ac, ac.templateId, ac.stakeholders)(
      (c, p) => c.copy(stakeholders = p.toSet)
    )
  }

  private def applyRequestingWitnesses[A](
      filter: TemplateAwareFilter,
      a: A,
      tid: Ref.Identifier,
      parties: Set[Party])(partySetter: (A, Set[Party]) => A): Option[A] = {
    // The events are generated by the engine, then
    //  - we can assert identifier are always in `New Style`
    //  - witnesses are party
    val requestingWitnesses =
      parties.filter(e => filter.subscribersByTemplateId(tid).contains(Party.assertFromString(e)))
    if (requestingWitnesses.nonEmpty)
      Some(partySetter(a, requestingWitnesses))
    else
      None
  }
}
