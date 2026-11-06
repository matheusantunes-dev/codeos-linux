/*
 * Vigia do papel de parede do CodeOS (autostart da sessão): com a chave "Aplicar em todas as telas"
 * ligada (xfce4-desktop /codeos/all-displays), o papel de parede escolhido numa tela vai para todas as
 * telas e áreas de trabalho. É a parte que fica rodando o tempo todo; a janela com a chave continua em
 * codeos-wallpaper (Python). Em Python o vigia ocupava ~20 MB parado; aqui, ~2 MB.
 *
 *   gcc -O2 -o codeos-wallpaper-sync codeos-wallpaper-sync.c \
 *       $(pkg-config --cflags --libs libxfconf-0 xrandr x11)
 */
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <xfconf/xfconf.h>
#include <string.h>

#define CANAL "xfce4-desktop"
#define CHAVE "/codeos/all-displays"

/* o que define a imagem de uma tela; a cor de fundo fica como estiver em cada uma */
static GRegex *chave_imagem;

static gboolean
eh_texto (const gchar *prop)
{
    return g_str_has_suffix (prop, "/last-image");
}

static gchar *
campo (const gchar *prop)
{
    GMatchInfo *m = NULL;
    gchar *res = NULL;
    if (g_regex_match (chave_imagem, prop, 0, &m))
        res = g_match_info_fetch (m, 1);
    g_match_info_free (m);
    return res;
}

static gboolean
iguais (XfconfChannel *ch, const gchar *a, const gchar *b)
{
    if (eh_texto (a)) {
        gchar *x = xfconf_channel_get_string (ch, a, ""), *y = xfconf_channel_get_string (ch, b, "");
        gboolean r = g_strcmp0 (x, y) == 0;
        g_free (x);
        g_free (y);
        return r;
    }
    return xfconf_channel_get_int (ch, a, 0) == xfconf_channel_get_int (ch, b, 0);
}

/* copia o valor de uma tela para a mesma chave de todas as telas e áreas de trabalho */
static void
espelhar (XfconfChannel *ch, const gchar *origem)
{
    gchar *qual = campo (origem);
    GHashTable *props = xfconf_channel_get_properties (ch, "/backdrop");
    GHashTableIter it;
    gpointer chave;

    if (qual == NULL || props == NULL) {
        g_free (qual);
        if (props != NULL)
            g_hash_table_destroy (props);
        return;
    }
    g_hash_table_iter_init (&it, props);
    while (g_hash_table_iter_next (&it, &chave, NULL)) {
        gchar *outro = campo (chave);
        if (outro != NULL && strcmp (outro, qual) == 0 && strcmp (chave, origem) != 0
            && !iguais (ch, chave, origem)) {
            if (eh_texto (origem)) {
                gchar *v = xfconf_channel_get_string (ch, origem, "");
                xfconf_channel_set_string (ch, chave, v);
                g_free (v);
            } else {
                xfconf_channel_set_int (ch, chave, xfconf_channel_get_int (ch, origem, 0));
            }
        }
        g_free (outro);
    }
    g_hash_table_destroy (props);
    g_free (qual);
}

/* "monitorHDMI-1/" da tela principal */
static gchar *
principal (void)
{
    Display *d = XOpenDisplay (NULL);
    gchar *res = g_strdup ("monitor");
    if (d != NULL) {
        Window raiz = DefaultRootWindow (d);
        RROutput saida = XRRGetOutputPrimary (d, raiz);
        XRRScreenResources *rec = XRRGetScreenResourcesCurrent (d, raiz);
        if (saida != None && rec != NULL) {
            XRROutputInfo *info = XRRGetOutputInfo (d, rec, saida);
            if (info != NULL) {
                g_free (res);
                res = g_strdup_printf ("monitor%s/", info->name);
                XRRFreeOutputInfo (info);
            }
        }
        if (rec != NULL)
            XRRFreeScreenResources (rec);
        XCloseDisplay (d);
    }
    return res;
}

static void
mudou (XfconfChannel *ch, const gchar *prop, const GValue *valor, gpointer dados)
{
    if (!xfconf_channel_get_bool (ch, CHAVE, TRUE))
        return;
    if (g_regex_match (chave_imagem, prop, 0, NULL)) {
        /* as cópias também disparam este sinal, mas já chegam iguais e não são copiadas de novo */
        espelhar (ch, prop);
    } else if (strcmp (prop, CHAVE) == 0) {
        /* ao ligar a chave, todas as telas ficam com o papel de parede da tela principal */
        gchar *tela = principal ();
        GHashTable *props = xfconf_channel_get_properties (ch, "/backdrop");
        GHashTableIter it;
        gpointer chave;
        if (props != NULL) {
            g_hash_table_iter_init (&it, props);
            while (g_hash_table_iter_next (&it, &chave, NULL))
                if (g_regex_match (chave_imagem, chave, 0, NULL) && strstr (chave, "/workspace0/") != NULL
                    && strstr (chave, tela) != NULL)
                    espelhar (ch, chave);
            g_hash_table_destroy (props);
        }
        g_free (tela);
    }
}

int
main (void)
{
    XfconfChannel *ch;
    GError *erro = NULL;

    if (!xfconf_init (&erro)) {
        g_printerr ("xfconf: %s\n", erro->message);
        return 1;
    }
    chave_imagem = g_regex_new ("^/backdrop/screen\\d+/monitor[^/]+/workspace\\d+/(last-image|image-style)$",
                                0, 0, NULL);
    ch = xfconf_channel_new (CANAL);
    g_signal_connect (ch, "property-changed", G_CALLBACK (mudou), NULL);
    g_main_loop_run (g_main_loop_new (NULL, FALSE));
    return 0;
}
