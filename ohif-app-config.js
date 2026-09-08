window.config = {
  routerBasename: '/',
  extensions: [],
  modes: [],
  showStudyList: true,
  dataSources: [
    {
      namespace: '@ohif/extension-default.dataSourcesModule.dicomweb',
      sourceName: 'orthanc',
      configuration: {
        friendlyName: 'OpenMRS Orthanc PACS',
        name: 'orthanc',
        // Browser-side URLs: OHIF runs client-side JS, so these must be
        // reachable from the radiologist's browser, not just container-to-container.
        // Same origin as the viewer itself - NPM proxy host 3 serves OHIF at / and
        // routes /dicom-web and /wado to orthanc-cors-proxy, which injects Basic
        // Auth server-side. Same-origin means no CORS preflight, and no credential
        // needs to live in this file.
        wadoUriRoot: 'https://viewer.hospital.lan/wado',
        qidoRoot: 'https://viewer.hospital.lan/dicom-web',
        wadoRoot: 'https://viewer.hospital.lan/dicom-web',
        qidoSupportsIncludeField: true,
        supportsReject: true,
        imageRendering: 'wadors',
        thumbnailRendering: 'wadors',
        enableStudyLazyLoad: true,
        supportsFuzzyMatching: true,
        supportsWildcard: true,
      },
    },
  ],
  defaultDataSourceName: 'orthanc',
};
