--liquibase formatted sql

--changeset jrose:55269789-6690-400A-A4CF-D06E5F646EDE stripComments:false runOnChange:true endDelimiter:/

/*=============================================
             :
      Author : Zaher
             :
 Description : Returns a winner for an event for use on CRM.
             :
       Usage : EXEC [Report].[P_Report_Get_Event_Winner] 2, 1, 4, 0
             :
  CRM Report : Marketing - Event - Draw Winner
             :
  NG20211117 : Added Blacklisting of Accounts, ability to choose number of Winners and select
             :     which active event they would like to use.
  NG20211122 : Removed LocationMapping tables and replaced with Customer tables for location.
  NG20220228 : Added Carrier filtering and refactored report for potential future event use
  MR20220309 : Removed the join to dbo.order_no on entryID, and added restraint of event Id 5
             :     to blacklist table, and moved the SET @FinalRowCount = @FinalRowCount + 1 up higher.
  MR20220413 : Added the "Delete from blacklist table" script at the beginning. Kristine wants winners
             :     to be able to win again for the last two drawings (but not twice within the same
             :     drawing, so the later entry into the blacklist table will remain).
  MR20230217 : Changed the blacklist logic to only look for this event.
  JR20240206 : Formatting.
             :
 =============================================*/
CREATE OR ALTER PROCEDURE [Report].[P_Report_Get_Event_Winner]
    (
        @SessionAccountID INT,
        @NumberOfWinners INT,
        @EventID INT,
        @Carrier INT -- Verizon 0, Tracfone 1
    )
AS
BEGIN
    BEGIN TRY

        IF @SessionAccountID <> 2
            BEGIN
                SELECT
                    -- noqa: disable=all
                    'This report is highly restricted! If you need access, please contact your T-Cetra representative.' AS [Access Error];
                    -- noqa: enable=all
                RETURN;
            END;

        IF OBJECT_ID('tempdb..#raffelentries') IS NOT NULL
            BEGIN
                DROP TABLE #raffelentries
            END

        CREATE TABLE #raffelentries
        (
            AccountID INT,
            Entries DECIMAL(7, 2)
        );

        IF @Carrier = 0
            BEGIN
                INSERT INTO #raffelentries (AccountID, Entries)
                SELECT ev.AccountId, SUM(ev.NumberOfEntries * ev.WeightOfEntries) AS Entries

                FROM [Marketing].[tblEventEntries] AS ev WITH (NOLOCK)
                JOIN dbo.Account AS ac WITH (NOLOCK) ON ac.Account_ID = ev.AccountID -- MR20220309 removed dbo.order_no

                JOIN CarrierSetup.tblVzwAccountStore AS vzwa WITH (NOLOCK) ON ac.Account_ID = vzwa.AccountId
                JOIN CarrierSetup.tblVzwAccountStoreStatus AS vsst WITH (NOLOCK) ON vsst.StatusID = vzwa.StatusID

                WHERE
                    vzwa.AccountId IN (SELECT CAST(AccountId AS BIGINT) FROM Marketing.tblEventEntries)
                    AND vsst.StatusID NOT IN (2, 5, 8, 9, 10, 11, 255)
                    AND ev.EventId = @EventID

                GROUP BY ev.AccountId
            END;
        ELSE IF @Carrier = 1
            BEGIN
                INSERT INTO #raffelentries (AccountID, Entries)
                SELECT ev.AccountId, SUM(ev.NumberOfEntries * ev.WeightOfEntries) AS Entries

                FROM [Marketing].[tblEventEntries] AS ev WITH (NOLOCK)
                JOIN dbo.Account AS ac WITH (NOLOCK) ON ac.Account_ID = ev.AccountID

                JOIN
                    Tracfone.tblTracTSPAccountRegistration AS tfr WITH (NOLOCK)
                    ON tfr.Account_ID = CAST(ac.Account_ID AS VARCHAR(30))
                JOIN
                    Tracfone.tblTracfoneDealerStatus AS tds WITH (NOLOCK)
                    ON tds.TracfoneDealerStatusID = tfr.TracfoneStatus

                WHERE
                    tfr.Account_ID IN (SELECT CAST(ee.AccountId AS BIGINT) FROM Marketing.tblEventEntries AS ee)
                    AND tds.TracfoneDealerStatusID NOT IN (2, 3, 7, 8, 10)
                    AND ev.EventId = @EventID

                GROUP BY ev.AccountId
            END

        IF OBJECT_ID('tempdb..#results') IS NOT NULL
            BEGIN
                DROP TABLE #results
            END

        CREATE TABLE #results (
            RowID INT IDENTITY (1, 1),
            AccountID INT,
            Account_Name VARCHAR(MAX),
            Address VARCHAR(MAX),
            Address2 VARCHAR(MAX),
            City VARCHAR(MAX),
            State VARCHAR(MAX),
            ZipCode VARCHAR(MAX),
            Entries DECIMAL(7, 2),
            Starting_Entry VARCHAR(MAX),
            Ending_Entry VARCHAR(MAX),
            DrawNumber FLOAT,
            Result VARCHAR(MAX)
        )
        DECLARE
            @rnd FLOAT,
            @RowCount INT,
            @FinalRowCount INT

        INSERT INTO #results (AccountID, Entries, Starting_Entry, Ending_Entry)
        SELECT
            rf.AccountID,
            rf.Entries,
            rf.Starting_Entry,
            rf.Ending_Entry

        FROM (
            SELECT
                t1.AccountID
                , t1.Entries,
                ISNULL((
                    SELECT SUM(t2.Entries)
                    FROM #raffelentries AS t2
                    WHERE t2.AccountID < t1.AccountID
                ),
                0) AS [Starting_Entry],

                ISNULL((
                    SELECT SUM(t2.Entries)
                    FROM #raffelentries AS t2
                    WHERE t2.AccountID <= t1.AccountID
                ),
                0) AS [Ending_Entry]
            FROM #raffelentries AS t1
        )
            AS rf

        IF OBJECT_ID('tempdb..#WinnerAccountID') IS NOT NULL
            BEGIN
                DROP TABLE #WinnerAccountID
            END

        CREATE TABLE #WinnerAccountID (AccountID INT)

        IF OBJECT_ID('tempdb..#results2') IS NOT NULL
            BEGIN
                DROP TABLE #results2
            END

        CREATE TABLE #results2 (
            AccountID INT,
            Account_Name VARCHAR(MAX),
            Address VARCHAR(MAX),
            Address2 VARCHAR(MAX),
            City VARCHAR(MAX),
            State VARCHAR(MAX),
            ZipCode VARCHAR(MAX),
            Entries DECIMAL(7, 2),
            Starting_Entry VARCHAR(MAX),
            Ending_Entry VARCHAR(MAX),
            DrawNumber FLOAT,
            Result VARCHAR(MAX)
        )
        SET @RowCount = 1
        SET @FinalRowCount = 1

        WHILE @RowCount <= @NumberOfWinners
            BEGIN
                SET @rnd = RAND() * (SELECT SUM(entries) FROM #raffelentries);

                INSERT INTO #results2 (
                    AccountID,
                    Account_Name,
                    Address,
                    Address2,
                    City,
                    State,
                    ZipCode,
                    entries,
                    Starting_Entry,
                    Ending_Entry,
                    DrawNumber,
                    Result
                )
                OUTPUT Inserted.AccountID
                INTO #WinnerAccountID
                SELECT
                    AccountID,
                    Account_Name,
                    Address,
                    Address2,
                    City,
                    State,
                    ZipCode,
                    entries,
                    Starting_Entry,
                    Ending_Entry,
                    @rnd AS DrawNumber,
                    'Winner' AS Result
                FROM #results
                WHERE
                    CASE
                        WHEN Starting_entry <= @rnd AND @rnd < Ending_entry
                            THEN 'Winner'
                        ELSE ''
                    END = 'Winner'
                    --MR20220309
                    AND AccountID NOT IN (SELECT AccountID FROM Marketing.tblEventBlacklist WHERE EventID = @EventID)

                IF @@ROWCOUNT > 0
                    BEGIN
                        SET @RowCount = @RowCount + 1
                        SET @FinalRowCount = @FinalRowCount + 1            --MR20220309

                        INSERT INTO Marketing.tblEventBlacklist (AccountID, EventID, DateAdded)
                        SELECT AccountID, @EventID AS EventID, GETDATE() AS DateAdded FROM #WinnerAccountID

                        DELETE FROM #WinnerAccountID
                    END;


                IF @FinalRowCount > @NumberOfWinners BREAK;
            END;

        SELECT
            ac.Account_ID AS [AccountID]
            , ac.Account_Name AS [Account Name]
            , cu.Address1 AS [Address1]
            , cu.Address2 AS [Address2]
            , cu.City AS [City]
            , cu.State AS [State]
            , cu.Zip AS [Zip]
            , a2.Account_Name AS [TopParentName]
            , r2.Entries AS [Entries]
            , r2.Starting_Entry AS [Starting Entry]
            , r2.Ending_Entry AS [Ending Entry]
            , r2.DrawNumber
            , r2.Result

        FROM #results2 AS r2
        JOIN dbo.Account AS ac WITH (NOLOCK) ON ac.Account_ID = r2.AccountID
        JOIN dbo.Customers AS cu WITH (NOLOCK) ON cu.Customer_ID = ac.Customer_ID
        JOIN dbo.Account AS a2 WITH (NOLOCK) ON a2.Account_ID = dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy)

    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH
END
-- noqa: disable=all
/
