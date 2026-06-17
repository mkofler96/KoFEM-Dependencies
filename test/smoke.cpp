// test/smoke.cpp — pipeline MVP: prove OCCT, Netgen and MFEM link and run
// together in the WASM build environment.
//
// Built and executed under node at image-build time by test/run-smoke.sh, so a
// broken dependency pipeline fails THIS image instead of surfacing 20 minutes
// later in the downstream engine build.
//
// The MFEM section deliberately reaches the element classes only through MFEM's
// high-level API and virtual dispatch (GetFE()->CalcShape(), etc.) — the same
// path the engine uses — so it also exercises the vtable-survival fix from
// KoFEM#175 at runtime, not just the link-time symbol check in build-mfem.sh.

#include <cmath>
#include <cstdio>

// ── OCCT ─────────────────────────────────────────────────────────────────────
#include <BRepPrimAPI_MakeBox.hxx>
#include <TopoDS_Shape.hxx>
#include <TopExp_Explorer.hxx>
#include <TopAbs_ShapeEnum.hxx>

// ── Netgen (nglib C API) ──────────────────────────────────────────────────────
#include <nglib.h>

// ── MFEM ─────────────────────────────────────────────────────────────────────
#include "mfem.hpp"

static int g_failures = 0;
static void check(bool ok, const char *what)
{
    std::printf("  [%s] %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) { ++g_failures; }
}

int main()
{
    std::printf("== KoFEM dependency smoke test ==\n");

    // OCCT: build a solid box and count its faces (a box has exactly 6).
    {
        TopoDS_Shape box = BRepPrimAPI_MakeBox(1.0, 2.0, 3.0).Shape();
        int nfaces = 0;
        for (TopExp_Explorer ex(box, TopAbs_FACE); ex.More(); ex.Next()) { ++nfaces; }
        check(nfaces == 6, "OCCT  : BRepPrimAPI_MakeBox -> 6 faces");
    }

    // Netgen: bring up the nglib runtime and allocate/free an empty mesh.
    {
        nglib::Ng_Init();
        nglib::Ng_Mesh *m = nglib::Ng_NewMesh();
        int np = (m != nullptr) ? nglib::Ng_GetNP(m) : -1;
        if (m != nullptr) { nglib::Ng_DeleteMesh(m); }
        nglib::Ng_Exit();
        check(m != nullptr && np == 0, "Netgen: nglib Ng_NewMesh -> empty mesh");
    }

    // MFEM: build a tet mesh + H1 space, then exercise element shape functions
    // through virtual dispatch (the SetIntPoint/CalcShape/CalcDShape path that
    // KoFEM#172 trapped on when the vtables were stripped).
    {
        mfem::Mesh mesh =
            mfem::Mesh::MakeCartesian3D(1, 1, 1, mfem::Element::TETRAHEDRON);
        mfem::H1_FECollection fec(1, mesh.Dimension());
        mfem::FiniteElementSpace fes(&mesh, &fec);

        const mfem::FiniteElement *fe = fes.GetFE(0);
        mfem::ElementTransformation *T = fes.GetElementTransformation(0);

        mfem::IntegrationPoint ip;
        ip.Set3(0.25, 0.25, 0.25);
        T->SetIntPoint(&ip);                                   // virtual

        mfem::Vector shape(fe->GetDof());
        fe->CalcShape(ip, shape);                              // virtual

        mfem::DenseMatrix dshape(fe->GetDof(), mesh.Dimension());
        fe->CalcDShape(ip, dshape);                            // virtual

        // Nodal H1 shape functions form a partition of unity: they sum to 1
        // at any point. This confirms the virtual calls returned real data,
        // not a trapped/garbage dispatch.
        check(mesh.GetNE() > 0, "MFEM  : MakeCartesian3D -> tet mesh");
        check(std::abs(shape.Sum() - 1.0) < 1e-9,
              "MFEM  : virtual dispatch (SetIntPoint/CalcShape/CalcDShape)");
    }

    if (g_failures == 0)
    {
        std::printf("== ALL OK ==\n");
        return 0;
    }
    std::printf("== %d CHECK(S) FAILED ==\n", g_failures);
    return 1;
}
