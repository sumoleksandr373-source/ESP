// SCESP.mm v4 — StandChillow (Unity IL2CPP, iOS arm64), ESP for offline bot matches
//
// Box / skeleton / chams / box fill, enemies only (teammates optional), settings panel.
// Tap the small "ESP" plate (top-left) to open/close the settings panel.
//
// - everything is resolved by class/method name at runtime through the exported il2cpp API
// - team comes from the PlayerController fields typed Core.Team; "me" is the character at the camera
// - skeleton = real bones of each character's biggest SkinnedMeshRenderer, parent->child lines
// - chams = swaps the enemy's materials for an unlit colour material that ignores depth
//   (needs a built-in shader that exists in the build; the panel shows which one it found)
// - hot path uses direct method-pointer calls; drawing is 30 fps, scan about once a second
//
// Not compiled or run on a device by me. If something misbehaves, the panel's status line says where.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <vector>

// ---- config ----------------------------------------------------------------------------
static const char *kGameImage = "Chillow.StandChillow.Client.dll";
struct Target { const char *ns; const char *name; };
static const Target kTargets[] = {
    {"Chillow.StandChillow.Player", "PlayerController"},
    {"Chillow.StandChillow.Player", "CharacterPlayer"},
    {"Chillow.StandChillow.Bots.Core", "BotPlayerController"},
};
static const int   kN = sizeof(kTargets) / sizeof(kTargets[0]);
static const char *kTeamType = "Chillow.StandChillow.Core.Team";   // None=0 Tr=1 Ct=2 Spectator=3
static const float kSelfRadius = 0.7f;
static const int   kRefreshTicks = 30;
static const char *kChamShaders[] = { "Hidden/Internal-Colored", "UI/Default", "Sprites/Default" };

// ---- settings --------------------------------------------------------------------------
struct Settings {
    bool on = true, box = true, skel = true, chams = false, fill = false, team = false, lowcpu = false;
    int color = 0;
    float lw = 1.5f;
    float head = 1.8f;
};
static Settings g_set;
static bool g_dirty = true;

static UIColor *colorFor(int i, CGFloat a) {
    switch (i) {
        case 0: return [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:a];
        case 1: return [UIColor colorWithRed:0.1 green:1 blue:0.2 alpha:a];
        case 2: return [UIColor colorWithRed:0.1 green:0.9 blue:1 alpha:a];
        case 3: return [UIColor colorWithRed:1 green:0.9 blue:0.1 alpha:a];
        case 4: return [UIColor colorWithRed:1 green:1 blue:1 alpha:a];
        case 5: return [UIColor colorWithRed:1 green:0.2 blue:1 alpha:a];
        default: return [UIColor colorWithRed:1 green:0.55 blue:0.1 alpha:a];
    }
}
static void saveSettings() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:g_set.on forKey:@"scesp_on"];       [d setBool:g_set.box forKey:@"scesp_box"];
    [d setBool:g_set.skel forKey:@"scesp_skel"];   [d setBool:g_set.chams forKey:@"scesp_chams"];
    [d setBool:g_set.fill forKey:@"scesp_fill"];   [d setBool:g_set.team forKey:@"scesp_team"];
    [d setBool:g_set.lowcpu forKey:@"scesp_low"];
    [d setInteger:g_set.color forKey:@"scesp_color"];
    [d setFloat:g_set.lw forKey:@"scesp_lw"];      [d setFloat:g_set.head forKey:@"scesp_head"];
}
static void loadSettings() {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![d objectForKey:@"scesp_on"]) return;
    g_set.on = [d boolForKey:@"scesp_on"];         g_set.box = [d boolForKey:@"scesp_box"];
    g_set.skel = [d boolForKey:@"scesp_skel"];     g_set.chams = [d boolForKey:@"scesp_chams"];
    g_set.fill = [d boolForKey:@"scesp_fill"];     g_set.team = [d boolForKey:@"scesp_team"];
    g_set.lowcpu = [d boolForKey:@"scesp_low"];
    g_set.color = (int)[d integerForKey:@"scesp_color"];
    g_set.lw = [d floatForKey:@"scesp_lw"];        g_set.head = [d floatForKey:@"scesp_head"];
    if (g_set.lw < 0.5f) g_set.lw = 1.5f;
    if (g_set.head < 1.0f) g_set.head = 1.8f;
}

// ---- il2cpp API ------------------------------------------------------------------------
typedef void *(*fn_domain_get)(void);
typedef void **(*fn_domain_get_assemblies)(void *, size_t *);
typedef void *(*fn_assembly_get_image)(void *);
typedef const char *(*fn_image_get_name)(void *);
typedef void *(*fn_class_from_name)(void *, const char *, const char *);
typedef void *(*fn_class_get_method)(void *, const char *, int);
typedef void *(*fn_runtime_invoke)(void *, void *, void **, void **);
typedef void *(*fn_class_get_type)(void *);
typedef void *(*fn_type_get_object)(void *);
typedef uint32_t (*fn_gchandle_new)(void *, int);
typedef void *(*fn_gchandle_get)(uint32_t);
typedef void (*fn_gchandle_free)(uint32_t);
typedef void *(*fn_class_get_fields)(void *, void **);
typedef void *(*fn_class_get_methods)(void *, void **);
typedef void *(*fn_class_get_parent)(void *);
typedef void *(*fn_field_get_type)(void *);
typedef int (*fn_field_get_offset)(void *);
typedef int (*fn_field_get_flags)(void *);
typedef char *(*fn_type_get_name)(void *);
typedef const char *(*fn_method_get_name)(void *);
typedef uint32_t (*fn_method_param_count)(void *);
typedef void *(*fn_method_get_param)(void *, uint32_t);
typedef void *(*fn_string_new)(const char *);
typedef void *(*fn_object_new)(void *);
typedef void *(*fn_array_new)(void *, uintptr_t);

static fn_domain_get il2_domain_get;
static fn_domain_get_assemblies il2_get_assemblies;
static fn_assembly_get_image il2_asm_image;
static fn_image_get_name il2_image_name;
static fn_class_from_name il2_class_from_name;
static fn_class_get_method il2_get_method;
static fn_runtime_invoke il2_invoke;
static fn_class_get_type il2_class_type;
static fn_type_get_object il2_type_object;
static fn_gchandle_new il2_gc_new;
static fn_gchandle_get il2_gc_get;
static fn_gchandle_free il2_gc_free;
static fn_class_get_fields il2_class_fields;
static fn_class_get_methods il2_class_methods;
static fn_class_get_parent il2_class_parent;
static fn_field_get_type il2_field_type;
static fn_field_get_offset il2_field_offset;
static fn_field_get_flags il2_field_flags;
static fn_type_get_name il2_type_name;
static fn_method_get_name il2_method_name;
static fn_method_param_count il2_method_pcount;
static fn_method_get_param il2_method_param;
static fn_string_new il2_string_new;
static fn_object_new il2_object_new;
static fn_array_new il2_array_new;

struct V3 { float x, y, z; };
struct Col { float r, g, b, a; };

typedef void *(*d_get_main)(void *mi);
typedef void *(*d_obj_get)(void *self, void *mi);
typedef V3 (*d_get_position)(void *self, void *mi);
typedef V3 (*d_w2s)(void *self, V3 p, void *mi);
typedef int (*d_screen)(void *mi);

static void *sym(const char *n) {
    void *p = dlsym(RTLD_DEFAULT, n);
    if (!p) NSLog(@"[SCESP] missing symbol %s", n);
    return p;
}

static bool loadApi() {
    il2_domain_get      = (fn_domain_get)sym("il2cpp_domain_get");
    il2_get_assemblies  = (fn_domain_get_assemblies)sym("il2cpp_domain_get_assemblies");
    il2_asm_image       = (fn_assembly_get_image)sym("il2cpp_assembly_get_image");
    il2_image_name      = (fn_image_get_name)sym("il2cpp_image_get_name");
    il2_class_from_name = (fn_class_from_name)sym("il2cpp_class_from_name");
    il2_get_method      = (fn_class_get_method)sym("il2cpp_class_get_method_from_name");
    il2_invoke          = (fn_runtime_invoke)sym("il2cpp_runtime_invoke");
    il2_class_type      = (fn_class_get_type)sym("il2cpp_class_get_type");
    il2_type_object     = (fn_type_get_object)sym("il2cpp_type_get_object");
    il2_gc_new          = (fn_gchandle_new)sym("il2cpp_gchandle_new");
    il2_gc_get          = (fn_gchandle_get)sym("il2cpp_gchandle_get_target");
    il2_gc_free         = (fn_gchandle_free)sym("il2cpp_gchandle_free");
    il2_class_fields    = (fn_class_get_fields)sym("il2cpp_class_get_fields");
    il2_class_methods   = (fn_class_get_methods)sym("il2cpp_class_get_methods");
    il2_class_parent    = (fn_class_get_parent)sym("il2cpp_class_get_parent");
    il2_field_type      = (fn_field_get_type)sym("il2cpp_field_get_type");
    il2_field_offset    = (fn_field_get_offset)sym("il2cpp_field_get_offset");
    il2_field_flags     = (fn_field_get_flags)sym("il2cpp_field_get_flags");
    il2_type_name       = (fn_type_get_name)sym("il2cpp_type_get_name");
    il2_method_name     = (fn_method_get_name)sym("il2cpp_method_get_name");
    il2_method_pcount   = (fn_method_param_count)sym("il2cpp_method_get_param_count");
    il2_method_param    = (fn_method_get_param)sym("il2cpp_method_get_param");
    il2_string_new      = (fn_string_new)sym("il2cpp_string_new");
    il2_object_new      = (fn_object_new)sym("il2cpp_object_new");
    il2_array_new       = (fn_array_new)sym("il2cpp_array_new");
    return il2_domain_get && il2_get_assemblies && il2_asm_image && il2_image_name &&
           il2_class_from_name && il2_get_method && il2_invoke && il2_class_type &&
           il2_type_object && il2_gc_new && il2_gc_get && il2_gc_free && il2_class_fields &&
           il2_class_methods && il2_class_parent && il2_field_type && il2_field_offset &&
           il2_field_flags && il2_type_name && il2_method_name && il2_method_pcount &&
           il2_method_param && il2_string_new && il2_object_new && il2_array_new;
}

static void *findImage(const char *name) {
    size_t n = 0;
    void **asms = il2_get_assemblies(il2_domain_get(), &n);
    for (size_t i = 0; i < n; i++) {
        void *img = il2_asm_image(asms[i]);
        if (img && strcmp(il2_image_name(img), name) == 0) return img;
    }
    return nullptr;
}

// method lookup that tells overloads apart by their first parameter's type name
static void *findMethod(void *klass, const char *name, uint32_t argc, const char *p0) {
    void *iter = nullptr, *m;
    while ((m = il2_class_methods(klass, &iter))) {
        if (strcmp(il2_method_name(m), name) != 0 || il2_method_pcount(m) != argc) continue;
        if (!p0) return m;
        const char *tn = il2_type_name(il2_method_param(m, 0));
        if (tn && strcmp(tn, p0) == 0) return m;
    }
    return nullptr;
}

static void *inv(void *mi, void *obj, void **args) {
    if (!mi) return nullptr;
    void *exc = nullptr;
    void *r = il2_invoke(mi, obj, args, &exc);
    return exc ? nullptr : r;
}

// ---- resolved state --------------------------------------------------------------------
static void *k_targets[8];
static size_t g_counts[8];
static int g_active = -1;
static std::vector<int> g_teamOffsets;
static int g_teamField = -1;

static void *k_smr, *k_material, *k_shader;
static void *mi_find, *mi_get_bones, *mi_get_smats, *mi_set_smats, *mi_find_shader, *mi_mat_ctor;
static void *mi_set_color, *mi_set_queue, *mi_setint, *mi_setglobal;

static d_get_main d_cam_main;  static void *mi_cam_main;
static d_obj_get d_tr;         static void *mi_tr;
static d_obj_get d_parent;     static void *mi_parent;
static d_get_position d_pos;   static void *mi_pos;
static d_w2s d_world2screen;   static void *mi_w2s;
static d_screen d_sw, d_sh;    static void *mi_sw, *mi_sh;

static bool g_ready = false;
static bool g_apiOk = false;

static void *direct(void *methodInfo) { return methodInfo ? *(void **)methodInfo : nullptr; }

static bool resolveAll() {
    void *core = findImage("UnityEngine.CoreModule.dll");
    void *game = findImage(kGameImage);
    if (!core || !game) return false;

    void *cObject = il2_class_from_name(core, "UnityEngine", "Object");
    void *cCamera = il2_class_from_name(core, "UnityEngine", "Camera");
    void *cComp   = il2_class_from_name(core, "UnityEngine", "Component");
    void *cTrans  = il2_class_from_name(core, "UnityEngine", "Transform");
    void *cScreen = il2_class_from_name(core, "UnityEngine", "Screen");
    void *cRend   = il2_class_from_name(core, "UnityEngine", "Renderer");
    k_smr         = il2_class_from_name(core, "UnityEngine", "SkinnedMeshRenderer");
    k_material    = il2_class_from_name(core, "UnityEngine", "Material");
    k_shader      = il2_class_from_name(core, "UnityEngine", "Shader");
    if (!cObject || !cCamera || !cComp || !cTrans || !cScreen) return false;

    // FindObjectsOfType(Type) is stripped in this build; (Type, bool) is present.
    mi_find     = il2_get_method(cObject, "FindObjectsOfType", 2);
    mi_cam_main = il2_get_method(cCamera, "get_main", 0);
    mi_w2s      = il2_get_method(cCamera, "WorldToScreenPoint", 1);
    mi_tr       = il2_get_method(cComp, "get_transform", 0);
    mi_pos      = il2_get_method(cTrans, "get_position", 0);
    mi_parent   = il2_get_method(cTrans, "get_parent", 0);
    mi_sw       = il2_get_method(cScreen, "get_width", 0);
    mi_sh       = il2_get_method(cScreen, "get_height", 0);
    d_cam_main = (d_get_main)direct(mi_cam_main);
    d_world2screen = (d_w2s)direct(mi_w2s);
    d_tr  = (d_obj_get)direct(mi_tr);
    d_parent = (d_obj_get)direct(mi_parent);
    d_pos = (d_get_position)direct(mi_pos);
    d_sw  = (d_screen)direct(mi_sw);
    d_sh  = (d_screen)direct(mi_sh);

    // skeleton / chams helpers (all optional: missing ones just disable that feature)
    if (k_smr)  mi_get_bones = il2_get_method(k_smr, "get_bones", 0);
    if (cRend) {
        mi_get_smats = il2_get_method(cRend, "get_sharedMaterials", 0);
        mi_set_smats = il2_get_method(cRend, "set_sharedMaterials", 1);
    }
    if (k_shader) {
        mi_find_shader = findMethod(k_shader, "Find", 1, "System.String");
        mi_setglobal   = findMethod(k_shader, "SetGlobalFloat", 2, "System.String");
    }
    if (k_material) {
        mi_mat_ctor  = findMethod(k_material, ".ctor", 1, "UnityEngine.Shader");
        mi_set_color = il2_get_method(k_material, "set_color", 1);
        mi_set_queue = il2_get_method(k_material, "set_renderQueue", 1);
        mi_setint    = findMethod(k_material, "SetInt", 2, "System.String");
    }

    for (int i = 0; i < kN; i++) k_targets[i] = il2_class_from_name(game, kTargets[i].ns, kTargets[i].name);
    NSLog(@"[SCESP] resolve: find=%p cam=%p w2s=%p tr=%p pos=%p parent=%p bones=%p",
          mi_find, d_cam_main, d_world2screen, d_tr, d_pos, d_parent, mi_get_bones);
    bool any = false; for (int i = 0; i < kN; i++) if (k_targets[i]) any = true;
    return mi_find && d_cam_main && d_world2screen && d_tr && d_pos && d_sw && d_sh && any;
}

static void findTeamFields(void *klass) {
    g_teamOffsets.clear();
    g_teamField = -1;
    for (void *k = klass; k; k = il2_class_parent(k)) {
        void *iter = nullptr, *f;
        while ((f = il2_class_fields(k, &iter))) {
            if (il2_field_flags(f) & 0x10) continue;
            const char *tn = il2_type_name(il2_field_type(f));
            if (tn && strcmp(tn, kTeamType) == 0) g_teamOffsets.push_back(il2_field_offset(f));
        }
    }
}

static inline bool alive(void *obj) { return obj && *(void **)((char *)obj + 16) != nullptr; }
static inline int readTeam(void *obj, int field) {
    if (field < 0 || field >= (int)g_teamOffsets.size()) return 0;
    return *(int *)((char *)obj + g_teamOffsets[field]);
}

// ---- scene scan ------------------------------------------------------------------------
struct PlayerInfo {
    uint32_t obj = 0;
    std::vector<uint32_t> smr;      // SkinnedMeshRenderer handles belonging to this player
    std::vector<uint32_t> bone;     // Transform handles (biggest SMR's bones)
    std::vector<int> parent;        // parent index inside `bone`, or -1
};
static std::vector<PlayerInfo> g_pl;

static void freeInfo(PlayerInfo &p) {
    if (p.obj) il2_gc_free(p.obj);
    for (uint32_t h : p.smr) il2_gc_free(h);
    for (uint32_t h : p.bone) il2_gc_free(h);
}

static size_t findObjs(void *klass, std::vector<void *> &out, size_t cap) {
    void *typeObj = il2_type_object(il2_class_type(klass));
    bool inactive = false;
    void *args[2] = { typeObj, &inactive };
    void *arr = inv(mi_find, nullptr, args);
    if (!arr) return 0;
    uintptr_t len = *(uintptr_t *)((char *)arr + 24);
    void **elems = (void **)((char *)arr + 32);
    if (len > cap) len = cap;
    size_t n = 0;
    for (uintptr_t i = 0; i < len; i++) if (elems[i]) { out.push_back(elems[i]); n++; }
    return n;
}

static void rescan(bool wantBones) {
    std::vector<void *> objs;
    for (int t = 0; t < kN; t++) g_counts[t] = 0;
    if (g_active >= 0 && k_targets[g_active]) g_counts[g_active] = findObjs(k_targets[g_active], objs, 64);
    if (objs.empty()) {
        for (int t = 0; t < kN; t++) {
            if (!k_targets[t]) continue;
            g_counts[t] = findObjs(k_targets[t], objs, 64);
            if (g_counts[t] > 0) { if (g_active != t) { g_active = t; findTeamFields(k_targets[t]); } break; }
        }
    }

    std::vector<PlayerInfo> fresh(objs.size());
    for (size_t i = 0; i < objs.size(); i++) fresh[i].obj = il2_gc_new(objs[i], 0);

    if (wantBones && k_smr && mi_get_bones && d_parent && !objs.empty()) {
        // ancestors (self, parent, grandparent) of every player; unique ones identify the owner
        struct Anc { void *tr; int pl; int cnt; };
        std::vector<Anc> anc;
        for (size_t i = 0; i < objs.size(); i++) {
            void *tr = d_tr(objs[i], mi_tr);
            for (int lvl = 0; lvl < 3 && tr; lvl++) {
                bool found = false;
                for (auto &a : anc) if (a.tr == tr) { a.cnt++; found = true; break; }
                if (!found) anc.push_back({tr, (int)i, 1});
                tr = d_parent(tr, mi_parent);
            }
        }
        std::vector<void *> smrs;
        findObjs(k_smr, smrs, 512);
        std::vector<std::vector<void *>> mine(objs.size());
        for (void *smr : smrs) {
            void *tr = d_tr(smr, mi_tr);
            int owner = -1;
            for (int depth = 0; depth < 20 && tr && owner < 0; depth++) {
                for (auto &a : anc) if (a.tr == tr && a.cnt == 1) { owner = a.pl; break; }
                tr = d_parent(tr, mi_parent);
            }
            if (owner >= 0) mine[owner].push_back(smr);
        }
        for (size_t i = 0; i < objs.size(); i++) {
            void *best = nullptr; uintptr_t bestN = 0;
            for (void *smr : mine[i]) {
                fresh[i].smr.push_back(il2_gc_new(smr, 0));
                void *arr = inv(mi_get_bones, smr, nullptr);
                uintptr_t n = arr ? *(uintptr_t *)((char *)arr + 24) : 0;
                if (n > bestN) { bestN = n; best = arr; }
            }
            if (!best) continue;
            if (bestN > 160) bestN = 160;
            void **bones = (void **)((char *)best + 32);
            std::vector<void *> bp;
            for (uintptr_t b = 0; b < bestN; b++) { bp.push_back(bones[b]); fresh[i].bone.push_back(bones[b] ? il2_gc_new(bones[b], 0) : 0); }
            for (uintptr_t b = 0; b < bestN; b++) {
                int pi = -1;
                if (bp[b]) {
                    void *par = d_parent(bp[b], mi_parent);
                    for (uintptr_t c = 0; c < bestN && par; c++) if (bp[c] == par) { pi = (int)c; break; }
                }
                fresh[i].parent.push_back(pi);
            }
        }
    }
    for (auto &p : g_pl) freeInfo(p);
    g_pl.swap(fresh);
}

// ---- chams -----------------------------------------------------------------------------
struct Cham { uint32_t rend; uint32_t orig; };
static std::vector<Cham> g_chams;
static uint32_t g_chamMat = 0;
static const char *g_chamShaderUsed = nullptr;
static bool g_chamFailed = false;
static int g_chamMode = 2;          // 0 = shader has _ZTest, 1 = UI/Default via unity_GUIZTestMode, 2 = no x-ray
static uint32_t g_ztName = 0;

static void setMatInt(void *mat, const char *name, int v) {
    void *s = il2_string_new(name);
    void *args[2] = { s, &v };
    inv(mi_setint, mat, args);
}
static void updateChamColor() {
    if (!g_chamMat || !mi_set_color) return;
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    UIColor *u = colorFor(g_set.color, 1);
    CGFloat r, g, b, a; [u getRed:&r green:&g blue:&b alpha:&a];
    Col c = { (float)r, (float)g, (float)b, 0.65f };
    void *args[1] = { &c };
    inv(mi_set_color, mat, args);
}
static bool ensureChamMaterial() {
    if (g_chamMat) return true;
    if (g_chamFailed || !mi_find_shader || !mi_mat_ctor || !k_material) { g_chamFailed = true; return false; }
    void *shader = nullptr;
    for (const char *nm : kChamShaders) {
        void *args[1] = { il2_string_new(nm) };
        shader = inv(mi_find_shader, nullptr, args);
        if (shader) { g_chamShaderUsed = nm; break; }
    }
    if (!shader) { g_chamFailed = true; return false; }
    void *mat = il2_object_new(k_material);
    void *cargs[1] = { shader };
    if (!mat || (inv(mi_mat_ctor, mat, cargs), false)) { g_chamFailed = true; return false; }
    g_chamMat = il2_gc_new(mat, 0);
    if (strcmp(g_chamShaderUsed, "Hidden/Internal-Colored") == 0) g_chamMode = 0;
    else if (strcmp(g_chamShaderUsed, "UI/Default") == 0 && mi_setglobal) g_chamMode = 1;
    else g_chamMode = 2;
    if (g_chamMode == 0 && mi_setint) { setMatInt(mat, "_ZTest", 8); setMatInt(mat, "_ZWrite", 0); setMatInt(mat, "_Cull", 0); }
    if (mi_set_queue) { int q = 3500; void *a[1] = { &q }; inv(mi_set_queue, mat, a); }
    updateChamColor();
    return true;
}
// UI/Default reads its ZTest from the global unity_GUIZTestMode; keep it on "Always" while chams are live
static void pumpChamZTest() {
    if (g_chamMode != 1 || !mi_setglobal || g_chams.empty()) return;
    if (!g_ztName) g_ztName = il2_gc_new(il2_string_new("unity_GUIZTestMode"), 0);
    void *nm = il2_gc_get(g_ztName);
    float v = 8.0f;
    void *args[2] = { nm, &v };
    inv(mi_setglobal, nullptr, args);
}
static void restoreCham(Cham &c) {
    void *r = il2_gc_get(c.rend), *orig = il2_gc_get(c.orig);
    if (r && alive(r) && orig) { void *a[1] = { orig }; inv(mi_set_smats, r, a); }
    il2_gc_free(c.rend); il2_gc_free(c.orig);
}
static void applyCham(void *rend) {
    void *orig = inv(mi_get_smats, rend, nullptr);
    if (!orig) return;
    uintptr_t n = *(uintptr_t *)((char *)orig + 24);
    if (n == 0 || n > 16) return;
    void *mat = il2_gc_get(g_chamMat);
    if (!mat) return;
    void *arr = il2_array_new(k_material, n);
    if (!arr) return;
    void **el = (void **)((char *)arr + 32);
    for (uintptr_t i = 0; i < n; i++) el[i] = mat;
    void *a[1] = { arr };
    if (inv(mi_set_smats, rend, a) == nullptr && false) return;
    g_chams.push_back({ il2_gc_new(rend, 0), il2_gc_new(orig, 0) });
}
// `want` = renderers that should carry chams right now (enemy SMRs); empty = restore everything
static void reconcileChams(const std::vector<void *> &want) {
    for (size_t i = 0; i < g_chams.size();) {
        void *r = il2_gc_get(g_chams[i].rend);
        bool keep = r && alive(r);
        if (keep) { keep = false; for (void *w : want) if (w == r) { keep = true; break; } }
        if (!keep) { restoreCham(g_chams[i]); g_chams.erase(g_chams.begin() + i); } else i++;
    }
    if (want.empty() || !mi_get_smats || !mi_set_smats || !ensureChamMaterial()) return;
    for (void *w : want) {
        bool has = false;
        for (auto &c : g_chams) if (il2_gc_get(c.rend) == w) { has = true; break; }
        if (!has) applyCham(w);
    }
}

// ---- UI --------------------------------------------------------------------------------
@interface SCESPDriver : NSObject
- (void)tick;
@end

@implementation SCESPDriver {
    UIView *_overlay;
    CAShapeLayer *_boxes, *_skel;
    UIButton *_btn;
    UIView *_panel;
    UILabel *_status;
    UILabel *_lwLabel, *_hdLabel;
    int _frame;
    double _lastTick, _lastScan;
}

- (UIWindow *)keyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)addSwitch:(NSString *)title col:(int)col row:(int)row tag:(int)tag on:(BOOL)on {
    CGFloat cx = col ? 170 : 10, y = 30 + row * 28;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(cx, y, 96, 26)];
    l.text = title; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12];
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.7;
    UISwitch *s = [[UISwitch alloc] init];
    s.transform = (CGAffineTransform){ 0.68, 0, 0, 0.68, 0, 0 };
    s.center = CGPointMake(cx + 96 + 20, y + 13);
    s.tag = tag; s.on = on;
    [s addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:l]; [_panel addSubview:s];
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(8, 72, 330, 268)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.9];
    _panel.layer.cornerRadius = 10;
    _panel.hidden = YES;

    UILabel *hd = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 330, 26)];
    hd.text = @"  \u2630  ESP settings  (drag here to move)";
    hd.textColor = UIColor.whiteColor; hd.font = [UIFont boldSystemFontOfSize:12];
    hd.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    hd.userInteractionEnabled = YES;
    hd.layer.cornerRadius = 10; hd.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    hd.clipsToBounds = YES;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panMoved:)];
    [hd addGestureRecognizer:pan];
    [_panel addSubview:hd];

    [self addSwitch:@"ESP" col:0 row:0 tag:0 on:g_set.on];
    [self addSwitch:@"Box" col:1 row:0 tag:1 on:g_set.box];
    [self addSwitch:@"Skeleton" col:0 row:1 tag:2 on:g_set.skel];
    [self addSwitch:@"Chams" col:1 row:1 tag:3 on:g_set.chams];
    [self addSwitch:@"Box fill" col:0 row:2 tag:4 on:g_set.fill];
    [self addSwitch:@"Teammates" col:1 row:2 tag:5 on:g_set.team];
    [self addSwitch:@"Low CPU" col:0 row:3 tag:6 on:g_set.lowcpu];

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"R", @"G", @"C", @"Y", @"W", @"M", @"O"]];
    seg.frame = CGRectMake(10, 148, 310, 26);
    seg.selectedSegmentIndex = g_set.color;
    [seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:seg];

    _lwLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 180, 150, 14)];
    _lwLabel.textColor = UIColor.whiteColor; _lwLabel.font = [UIFont systemFontOfSize:10];
    [_panel addSubview:_lwLabel];
    UISlider *s1 = [[UISlider alloc] initWithFrame:CGRectMake(10, 194, 150, 26)];
    s1.minimumValue = 0.5; s1.maximumValue = 4; s1.value = g_set.lw; s1.tag = 10;
    [s1 addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:s1];

    _hdLabel = [[UILabel alloc] initWithFrame:CGRectMake(170, 180, 150, 14)];
    _hdLabel.textColor = UIColor.whiteColor; _hdLabel.font = [UIFont systemFontOfSize:10];
    [_panel addSubview:_hdLabel];
    UISlider *s2 = [[UISlider alloc] initWithFrame:CGRectMake(170, 194, 150, 26)];
    s2.minimumValue = 1.4; s2.maximumValue = 2.2; s2.value = g_set.head; s2.tag = 11;
    [s2 addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:s2];

    _status = [[UILabel alloc] initWithFrame:CGRectMake(10, 224, 310, 38)];
    _status.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    _status.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _status.numberOfLines = 3;
    [_panel addSubview:_status];
    [self refreshLabels];
}

- (void)panMoved:(UIPanGestureRecognizer *)g {
    UIView *sv = _panel.superview;
    if (!sv) return;
    CGPoint t = [g translationInView:sv];
    CGPoint c = CGPointMake(_panel.center.x + t.x, _panel.center.y + t.y);
    CGSize hs = CGSizeMake(_panel.bounds.size.width / 2, _panel.bounds.size.height / 2);
    if (c.x < hs.width * 0.3) c.x = hs.width * 0.3;
    if (c.y < hs.height * 0.3) c.y = hs.height * 0.3;
    if (c.x > sv.bounds.size.width - hs.width * 0.3) c.x = sv.bounds.size.width - hs.width * 0.3;
    if (c.y > sv.bounds.size.height - hs.height * 0.3) c.y = sv.bounds.size.height - hs.height * 0.3;
    _panel.center = c;
    [g setTranslation:CGPointMake(0, 0) inView:sv];
}

- (void)refreshLabels {
    _lwLabel.text = [NSString stringWithFormat:@"Line width: %.1f", g_set.lw];
    _hdLabel.text = [NSString stringWithFormat:@"Box height m: %.2f", g_set.head];
}

- (void)swChanged:(UISwitch *)s {
    switch (s.tag) {
        case 0: g_set.on = s.on; break;
        case 1: g_set.box = s.on; break;
        case 2: g_set.skel = s.on; break;
        case 3: g_set.chams = s.on; break;
        case 4: g_set.fill = s.on; break;
        case 5: g_set.team = s.on; break;
        case 6: g_set.lowcpu = s.on; break;
    }
    g_dirty = true; saveSettings();
}
- (void)segChanged:(UISegmentedControl *)s { g_set.color = (int)s.selectedSegmentIndex; g_dirty = true; saveSettings(); }
- (void)slChanged:(UISlider *)s {
    if (s.tag == 10) g_set.lw = s.value; else g_set.head = s.value;
    [self refreshLabels]; saveSettings();
}
- (void)plateTapped { _panel.hidden = !_panel.hidden; }

// Called from a run-loop observer that fires AFTER Unity's frame callback, so bone and camera
// transforms are the ones of the frame that was just rendered (no one-frame lag).
- (void)tick {
    double now = CACurrentMediaTime();
    double minDt = g_set.lowcpu ? 0.030 : 0.0145;
    if (now - _lastTick < minDt) return;
    _lastTick = now;

    UIWindow *win = [self keyWindow];
    if (!win) return;
    if (!_btn) {
        _btn = [UIButton buttonWithType:UIButtonTypeCustom];
        _btn.frame = CGRectMake(8, 44, 64, 24);
        _btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _btn.layer.cornerRadius = 6;
        _btn.titleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        [_btn setTitle:@"ESP \u2699" forState:UIControlStateNormal];
        [_btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [_btn addTarget:self action:@selector(plateTapped) forControlEvents:UIControlEventTouchUpInside];
        [self buildPanel];
    }
    if (_btn.superview != win) { [_btn removeFromSuperview]; [win addSubview:_btn]; }
    if (_panel.superview != win) { [_panel removeFromSuperview]; [win addSubview:_panel]; }
    [win bringSubviewToFront:_panel];
    [win bringSubviewToFront:_btn];

    if (!g_ready) {
        if (_frame++ % 30) return;
        if (!g_apiOk) g_apiOk = loadApi();
        if (!g_apiOk) { _status.text = @"il2cpp API missing"; return; }
        if (!resolveAll()) { _status.text = @"waiting for game classes..."; return; }
        g_ready = true; _lastScan = 0;
    }
    if (!_overlay) {
        _overlay = [[UIView alloc] initWithFrame:win.bounds];
        _overlay.userInteractionEnabled = NO;
        _overlay.backgroundColor = UIColor.clearColor;
        _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _boxes = [CAShapeLayer layer]; _skel = [CAShapeLayer layer];
        _boxes.fillColor = UIColor.clearColor.CGColor; _skel.fillColor = UIColor.clearColor.CGColor;
        [_overlay.layer addSublayer:_boxes]; [_overlay.layer addSublayer:_skel];
    }
    if (_overlay.superview != win) { [_overlay removeFromSuperview]; [win insertSubview:_overlay belowSubview:_btn]; }

    UIBezierPath *boxPath = [UIBezierPath bezierPath];
    UIBezierPath *skelPath = [UIBezierPath bezierPath];
    int drawn = 0, myTeam = -1;
    bool camOk = false;
    std::vector<void *> wantChams;
    bool scanNow = false;

    if (g_set.on) {
        if (now - _lastScan > 1.0) { rescan(g_set.skel || g_set.chams || g_set.box); scanNow = true; _lastScan = now; }
        @try {
            void *cam = d_cam_main(mi_cam_main);
            int sw = d_sw(mi_sw), sh = d_sh(mi_sh);
            if (cam && alive(cam) && sw > 0 && sh > 0) {
                camOk = true;
                void *ctr = d_tr(cam, mi_tr);
                V3 camPos = d_pos(ctr, mi_pos);
                CGSize vs = _overlay.bounds.size;

                struct P { PlayerInfo *pi; void *obj; V3 pos; bool self; };
                std::vector<P> ps;
                for (auto &pi : g_pl) {
                    void *obj = il2_gc_get(pi.obj);
                    if (!alive(obj)) continue;
                    void *tr = d_tr(obj, mi_tr);
                    if (!tr) continue;
                    V3 pos = d_pos(tr, mi_pos);
                    float dx = pos.x - camPos.x, dz = pos.z - camPos.z;
                    ps.push_back({ &pi, obj, pos, dx * dx + dz * dz < kSelfRadius * kSelfRadius });
                }
                if (g_teamField < 0 && !g_teamOffsets.empty()) {
                    for (int f = 0; f < (int)g_teamOffsets.size(); f++) {
                        bool h1 = false, h2 = false;
                        for (auto &p : ps) { int v = readTeam(p.obj, f); if (v == 1) h1 = true; if (v == 2) h2 = true; }
                        if (h1 && h2) { g_teamField = f; break; }
                    }
                }
                for (auto &p : ps) if (p.self && g_teamField >= 0) myTeam = readTeam(p.obj, g_teamField);

                std::vector<CGPoint> sp; std::vector<char> okp;
                for (auto &p : ps) {
                    if (p.self) continue;
                    if (g_teamField >= 0) {
                        int tv = readTeam(p.obj, g_teamField);
                        if (tv != 1 && tv != 2) continue;
                        if (!g_set.team && (myTeam == 1 || myTeam == 2) && tv == myTeam) continue;
                    }
                    PlayerInfo &pi = *p.pi;
                    for (uint32_t h : pi.smr) { void *r = il2_gc_get(h); if (r) wantChams.push_back(r); }

                    size_t nb = pi.bone.size();
                    sp.assign(nb, CGPointMake(0, 0)); okp.assign(nb, 0);
                    float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
                    int good = 0;
                    for (size_t b = 0; b < nb; b++) {
                        void *bt = pi.bone[b] ? il2_gc_get(pi.bone[b]) : nullptr;
                        if (!alive(bt)) continue;
                        V3 w = d_pos(bt, mi_pos);
                        V3 s = d_world2screen(cam, w, mi_w2s);
                        if (s.z <= 0) continue;
                        CGFloat x = s.x / sw * vs.width, y = (1.0 - s.y / sh) * vs.height;
                        sp[b] = CGPointMake(x, y); okp[b] = 1; good++;
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                    bool haveBones = good >= 6;

                    if (g_set.skel && haveBones) {
                        for (size_t b = 0; b < nb; b++) {
                            int par = pi.parent[b];
                            if (par < 0 || !okp[b] || !okp[par]) continue;
                            [skelPath moveToPoint:sp[par]]; [skelPath addLineToPoint:sp[b]];
                        }
                    }
                    if (g_set.box || g_set.fill) {
                        CGRect r;
                        if (haveBones) {
                            CGFloat pad = 6;
                            r = CGRectMake(minX - pad, minY - pad * 2, (maxX - minX) + pad * 2, (maxY - minY) + pad * 3);
                        } else {
                            V3 head = { p.pos.x, p.pos.y + g_set.head, p.pos.z };
                            V3 a = d_world2screen(cam, head, mi_w2s), b = d_world2screen(cam, p.pos, mi_w2s);
                            if (a.z <= 0 || b.z <= 0) continue;
                            CGFloat hx = a.x / sw * vs.width, hy = (1.0 - a.y / sh) * vs.height;
                            CGFloat fx = b.x / sw * vs.width, fy = (1.0 - b.y / sh) * vs.height;
                            CGFloat bh = fy - hy; if (bh < 4) continue;
                            CGFloat bw = bh * 0.5, cx = (hx + fx) * 0.5;
                            r = CGRectMake(cx - bw / 2, hy, bw, bh);
                        }
                        [boxPath appendPath:[UIBezierPath bezierPathWithRect:r]];
                    }
                    drawn++;
                }
            }
        } @catch (...) {}
    }

    if (g_dirty || scanNow || !g_set.on) {
        @try {
            if (!g_set.on || !g_set.chams) wantChams.clear();
            reconcileChams(wantChams);
            if (g_dirty) updateChamColor();
        } @catch (...) {}
        g_dirty = false;
    }
    @try { pumpChamZTest(); } @catch (...) {}

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _boxes.frame = _overlay.bounds; _skel.frame = _overlay.bounds;
    _boxes.strokeColor = g_set.box ? colorFor(g_set.color, 1).CGColor : UIColor.clearColor.CGColor;
    _boxes.fillColor = g_set.fill ? colorFor(g_set.color, 0.18).CGColor : UIColor.clearColor.CGColor;
    _skel.strokeColor = colorFor(g_set.color, 1).CGColor;
    _boxes.lineWidth = g_set.lw; _skel.lineWidth = g_set.lw;
    _boxes.path = boxPath.CGPath; _skel.path = skelPath.CGPath;
    [CATransaction commit];

    if (!_panel.hidden) {
        NSMutableString *cs = [NSMutableString string];
        for (int i = 0; i < kN; i++) [cs appendFormat:@"%s%zu", i ? "/" : "", g_counts[i]];
        NSString *sh = g_chamShaderUsed ? [NSString stringWithUTF8String:g_chamShaderUsed] : (g_chamFailed ? @"no shader" : @"-");
        _status.text = [NSString stringWithFormat:@"found %@ | team f%d me%d | draw %d | cam %@\nchams: %@ | %s | %zu on",
                        cs, g_teamField, myTeam, drawn, camOk ? @"ok" : @"-", sh,
                        g_chamMode == 2 ? "NO x-ray" : "x-ray", g_chams.size()];
    }
}
@end

static SCESPDriver *g_driver;

typedef void *(*cf_obs_create)(void *alloc, unsigned long activities, bool repeats, long order, void (^block)(void *obs, unsigned long act));
typedef void *(*cf_main_loop)(void);
typedef void (*cf_add_obs)(void *rl, void *obs, void *mode);

__attribute__((constructor)) static void scesp_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        loadSettings();
        g_driver = [SCESPDriver new];
        // CoreFoundation is resolved at runtime so the dylib needs no extra link flags.
        cf_obs_create create = (cf_obs_create)dlsym(RTLD_DEFAULT, "CFRunLoopObserverCreateWithHandler");
        cf_main_loop mainLoop = (cf_main_loop)dlsym(RTLD_DEFAULT, "CFRunLoopGetMain");
        cf_add_obs addObs = (cf_add_obs)dlsym(RTLD_DEFAULT, "CFRunLoopAddObserver");
        void **commonModes = (void **)dlsym(RTLD_DEFAULT, "kCFRunLoopCommonModes");
        if (create && mainLoop && addObs && commonModes) {
            // kCFRunLoopBeforeWaiting = 1 << 5
            void *obs = create(nullptr, (1UL << 5), true, 0, ^(void *o, unsigned long act) { [g_driver tick]; });
            addObs(mainLoop(), obs, *commonModes);
            NSLog(@"[SCESP] loaded (runloop observer)");
        } else {
            CADisplayLink *dl = [CADisplayLink displayLinkWithTarget:g_driver selector:@selector(tick)];
            dl.preferredFramesPerSecond = 60;
            [dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            NSLog(@"[SCESP] loaded (display link fallback)");
        }
    });
}
