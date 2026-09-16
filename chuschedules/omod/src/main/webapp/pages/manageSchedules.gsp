<%
    ui.decorateWith("appui", "standardEmrPage", [ title: "Horaires récurrents" ])
    ui.includeCss("chuschedules", "chuschedules.css")
%>

<div class="chu-schedules">

    <h2>Horaires récurrents</h2>
    <p class="chu-intro">
        Définissez une fois les horaires de consultation d'un prestataire, puis générez les
        tranches de rendez-vous correspondantes jusqu'à un an à l'avance.
    </p>

    <p>
        <a class="button confirm" href="${ ui.pageLink('chuschedules', 'editSchedule') }">Nouvel horaire</a>
        <a class="button" href="${ ui.pageLink('chuschedules', 'exceptions') }">Jours fériés et congés</a>
    </p>

    <% if (templates.isEmpty()) { %>
        <div class="chu-empty">
            Aucun horaire récurrent n'est encore défini.
        </div>
    <% } else { %>
        <table class="chu-table">
            <thead>
                <tr>
                    <th>Nom</th>
                    <th>Prestataire</th>
                    <th>Lieu</th>
                    <th>Séances</th>
                    <th>Validité</th>
                    <th>Généré jusqu'au</th>
                    <th></th>
                </tr>
            </thead>
            <tbody>
            <% templates.each { template -> %>
                <tr class="${ template.active ? '' : 'chu-inactive' }">
                    <td>
                        ${ ui.encodeHtml(template.name) }
                        <% if (!template.active) { %><span class="chu-badge">inactif</span><% } %>
                    </td>
                    <td>${ ui.encodeHtml(template.provider?.name ?: '') }</td>
                    <td>${ ui.encodeHtml(template.location?.name ?: '') }</td>
                    <td class="chu-pattern">${ ui.encodeHtml(summaries[template.templateId]) }</td>
                    <td>
                        ${ ui.formatDatePretty(template.validFrom) }
                        &ndash;
                        ${ template.validTo ? ui.formatDatePretty(template.validTo) : 'sans fin' }
                    </td>
                    <td>
                        <% if (horizons[template.templateId]) { %>
                            ${ ui.formatDatePretty(horizons[template.templateId]) }
                        <% } else { %>
                            <span class="chu-muted">jamais généré</span>
                        <% } %>
                    </td>
                    <td class="chu-actions">
                        <a href="${ ui.pageLink('chuschedules', 'generate', [ templateId: template.templateId ]) }">Générer</a>
                        <a href="${ ui.pageLink('chuschedules', 'editSchedule', [ templateId: template.templateId ]) }">Modifier</a>
                    </td>
                </tr>
            <% } %>
            </tbody>
        </table>
    <% } %>

</div>
