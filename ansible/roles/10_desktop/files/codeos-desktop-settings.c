/*
 * Módulo GTK do CodeOS para o xfdesktop-settings: põe a caixa "Apply to all displays" logo abaixo de
 * "Apply to all workspaces". A caixa liga e desliga a chave xfce4-desktop /codeos/all-displays, que o
 * vigia codeos-wallpaper --sync usa para repetir o papel de parede em todas as telas.
 *
 * O xfdesktop-settings é compilado, então a caixa entra em tempo de execução: o wrapper
 * /usr/local/bin/xfdesktop-settings carrega este módulo por GTK_MODULES.
 *
 *   gcc -shared -fPIC -O2 -o libcodeos-desktop-settings.so codeos-desktop-settings.c $(pkg-config --cflags --libs gtk+-3.0)
 */
#include <gtk/gtk.h>
#include <locale.h>
#include <string.h>

#define WORKSPACES_ID "chk_apply_to_all"
#define DISPLAYS_ID   "chk_codeos_apply_to_all_displays"

static gboolean
ler_chave (void)
{
    gchar *saida = NULL, *erro = NULL;
    gboolean ativa = TRUE;  /* sem a chave, o vigia trata como ligada */

    if (g_spawn_command_line_sync ("xfconf-query -c xfce4-desktop -p /codeos/all-displays",
                                   &saida, &erro, NULL, NULL) && saida != NULL && *saida != '\0')
        ativa = g_str_has_prefix (saida, "true");
    g_free (saida);
    g_free (erro);
    return ativa;
}

static void
alternou (GtkToggleButton *caixa, gpointer dados)
{
    gchar *cmd = g_strdup_printf ("xfconf-query -c xfce4-desktop -p /codeos/all-displays -n -t bool -s %s",
                                  gtk_toggle_button_get_active (caixa) ? "true" : "false");
    g_spawn_command_line_async (cmd, NULL);
    g_free (cmd);
}

static const gchar *
rotulo (void)
{
    const gchar *idioma = setlocale (LC_MESSAGES, NULL);
    return (idioma != NULL && g_str_has_prefix (idioma, "pt")) ? "Aplicar em todas as telas"
                                                               : "Apply to all displays";
}

static void
acrescentar (GtkWidget *workspaces)
{
    GtkWidget *grade = gtk_widget_get_parent (workspaces);
    GtkWidget *caixa;
    gint coluna, linha;

    if (!GTK_IS_GRID (grade) || g_object_get_data (G_OBJECT (grade), DISPLAYS_ID) != NULL)
        return;

    gtk_container_child_get (GTK_CONTAINER (grade), workspaces, "left-attach", &coluna, "top-attach", &linha, NULL);
    gtk_grid_insert_row (GTK_GRID (grade), linha + 1);

    caixa = gtk_check_button_new_with_label (rotulo ());
    gtk_widget_set_name (caixa, DISPLAYS_ID);
    gtk_widget_set_halign (caixa, gtk_widget_get_halign (workspaces));
    gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (caixa), ler_chave ());
    g_signal_connect (caixa, "toggled", G_CALLBACK (alternou), NULL);
    gtk_grid_attach (GTK_GRID (grade), caixa, coluna, linha + 1, 1, 1);
    gtk_widget_show (caixa);

    g_object_set_data (G_OBJECT (grade), DISPLAYS_ID, caixa);
}

/* toda caixa de seleção que aparece passa por aqui; só a "Apply to all workspaces" interessa */
static gboolean
ao_mapear (GSignalInvocationHint *dica, guint n, const GValue *params, gpointer dados)
{
    GObject *obj = g_value_get_object (&params[0]);

    if (GTK_IS_CHECK_BUTTON (obj) && GTK_IS_BUILDABLE (obj)) {
        const gchar *nome = gtk_buildable_get_name (GTK_BUILDABLE (obj));
        if (nome != NULL && strcmp (nome, WORKSPACES_ID) == 0)
            acrescentar (GTK_WIDGET (obj));
    }
    return TRUE;
}

G_MODULE_EXPORT void
gtk_module_init (gint *argc, gchar ***argv)
{
    if (g_strcmp0 (g_get_prgname (), "xfdesktop-settings") != 0)
        return;
    g_signal_add_emission_hook (g_signal_lookup ("map", GTK_TYPE_WIDGET), 0, ao_mapear, NULL, NULL);
}
