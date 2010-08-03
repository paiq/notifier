#define SITENAME "Paiq"
#define SITEEXTNAME "Paiq.nl"

#ifdef DEBUG
	#define SITEHOST "test.paiq.nl:28713"
	#define ILMPHOST "test.paiq.nl"
	#define ILMPPORT "28713"
	#define ILMPSITEDIR "paiq.nl"
	#define UPDATEHOST "test.paiq.nl:28713"
#else
	#define SITEHOST "paiq.nl"
	#define ILMPHOST "paiq.nl"
	#define ILMPPORT "80"
	#define ILMPSITEDIR "paiq.nl"
	#define UPDATEHOST "paiq.nl"
#endif
