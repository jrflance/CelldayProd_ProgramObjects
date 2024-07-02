--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-24
-- Description: Process user feed.
-- =============================================
CREATE OR ALTER PROCEDURE [Account].[P_UpsertUsers]
    (
        @TopParentAccountId INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE
            @ClerkGroupId INT = 8,
            @ManagerGroupId INT = 9

        IF OBJECT_ID('tempdb..#UpsertUserResults') IS NOT NULL
            BEGIN
                DROP TABLE #UpsertUserResults;
            END;

        CREATE TABLE #UpsertUserResults
        (
            VidapayUserId INT NULL,
            VidapayUserName VARCHAR(100) NULL,
            SourceUserId VARCHAR(100) NULL,
            SourceUserName VARCHAR(100) NULL,
            FirstName VARCHAR(100) NULL,
            LastName VARCHAR(100) NULL,
            Email VARCHAR(100) NULL,
            UserType VARCHAR(100) NULL,
            LocationId VARCHAR(100) NULL,
            Change VARCHAR(100) NULL,
            AccountId VARCHAR(100) NULL,
            [Status] VARCHAR(100) NULL,
            [Message] VARCHAR(100) NULL,
            IntAccountId INT NULL
        )

        IF OBJECT_ID('tempdb..#MerchantAccountIds') IS NOT NULL
            BEGIN
                DROP TABLE #MerchantAccountIds;
            END;

        CREATE TABLE #MerchantAccountIds (AccountID INT NULL);

        INSERT INTO #MerchantAccountIds (AccountID)
        EXEC Account.P_Account_GetAccountList
            @AccountID = @TopParentAccountId,
            @UserID = 2,
            @AccountTypeID = '2,11',
            @AccountStatusID = '0,1,2,3,4,5,6',
            @Simplified = 1;

        IF OBJECT_ID('tempdb..#UploadedUsers') IS NOT NULL
            BEGIN
                DROP TABLE #UploadedUsers;
            END;

        CREATE TABLE #UploadedUsers
        (
            UserName VARCHAR(100) NOT NULL,
            SourceUserId VARCHAR(100) NULL,
            SourceUserName VARCHAR(100) NULL,
            FirstName VARCHAR(100) NULL,
            LastName VARCHAR(100) NULL,
            Email VARCHAR(100) NULL,
            UserType VARCHAR(100) NULL,
            LocationId VARCHAR(100) NULL,
            Change VARCHAR(100) NULL,
            AccountId VARCHAR(100) NULL,
            IntAccountId INT NOT NULL,
            GroupId INT NULL,
            IsActive BIT
        );
        CREATE NONCLUSTERED INDEX IX_UploadedUsers_UserName_AccountId
            ON #UploadedUsers (UserName, IntAccountId);

        INSERT INTO #UploadedUsers
        (
            UserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            IntAccountId,
            GroupId,
            IsActive
        )
        SELECT
            ISNULL(dbo.fnStripCharacters(uu.SourceUserName, '^a-z0-9'), '') AS UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            CASE
                WHEN TRY_CAST(TRIM(uu.AccountId) AS INT) IS NULL THEN -1
                ELSE uu.AccountId
            END AS IntAccountId,
            CASE
                WHEN uu.UserType = 'Manager' THEN @ManagerGroupId
                WHEN uu.UserType = 'Clerk' THEN @ClerkGroupId
                ELSE -1
            END AS GroupId,
            1 AS IsActive
        FROM Upload.tblUploadUsers AS uu
        WHERE uu.ProcessAccountId = @TopParentAccountId;

        IF NOT EXISTS (SELECT 1 FROM #UploadedUsers)
            BEGIN
                RETURN;
            END;

        DELETE uu
        FROM Upload.tblUploadUsers AS uu
        WHERE uu.ProcessAccountId = @TopParentAccountId

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            0 AS VidapayUserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'FAILED' AS [Status],
            'Error: Valid accountId must be provided' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        WHERE uu.IntAccountId = -1

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            0 AS VidapayUserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'FAILED' AS [Status],
            'Error: Username must be provided' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        WHERE
            uu.UserName = ''
            AND NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uur.IntAccountId = uu.IntAccountId AND uu.UserName = uur.VidapayUserName)

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            0 AS UserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'FAILED' AS [Status],
            'Error: Username can only exist once per account' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        WHERE
            EXISTS (
                SELECT 1
                FROM #UploadedUsers AS uu1
                WHERE uu1.IntAccountId = uu.IntAccountId AND uu1.UserName = uu.UserName
                GROUP BY uu1.IntAccountId, uu1.UserName
                HAVING COUNT(1) > 1
            )
            AND NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uu.IntAccountId = uur.IntAccountId AND uu.UserName = uur.VidapayUserName)

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            0 AS UserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'FAILED' AS [Status],
            'Error: Account is not in Master Agent Tree' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        WHERE
            NOT EXISTS (SELECT 1 FROM #MerchantAccountIds AS ma WHERE ma.AccountID = uu.IntAccountId)
            AND NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uu.IntAccountId = uur.IntAccountId AND uu.UserName = uur.VidapayUserName)

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            0 AS UserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'FAILED' AS [Status],
            'Error: User must be a Manager or Clerk' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        WHERE
            uu.GroupId NOT IN (@ClerkGroupId, @ManagerGroupId)
            AND NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uu.IntAccountId = uur.IntAccountId AND uu.UserName = uur.VidapayUserName)

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            0 AS UserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'FAILED' AS [Status],
            'Error: Invalid Email' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        WHERE
            uu.Email NOT LIKE '%_@__%.__%'
            AND NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uu.IntAccountId = uur.IntAccountId AND uu.UserName = uur.VidapayUserName)

        IF OBJECT_ID('tempdb..#ExistingUsers') IS NOT NULL
            BEGIN
                DROP TABLE #ExistingUsers;
            END;

        SELECT
            u.[User_ID] AS UserId,
            c.[Customer_ID] AS CustomerId,
            u.UserName,
            c.FirstName,
            c.LastName,
            c.Email,
            u.Account_ID AS AccountId,
            u.Group_ID AS GroupId,
            u.IsActive AS IsActive
        INTO #ExistingUsers
        FROM dbo.Users AS u
        JOIN dbo.Customers AS c ON c.Customer_ID = u.Customer_ID
        JOIN #MerchantAccountIds AS a ON u.Account_ID = a.AccountId
        WHERE NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uur.VidapayUserName = u.UserName AND uur.IntAccountId = u.Account_Id);

        IF OBJECT_ID('tempdb..#UpdatedUsers') IS NOT NULL
            BEGIN
                DROP TABLE #UpdatedUsers;
            END;

        SELECT
            eu.UserId,
            eu.CustomerId,
            uu.UserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.GroupId,
            uu.AccountId,
            uu.IsActive
        INTO #UpdatedUsers
        FROM #UploadedUsers AS uu
        JOIN #ExistingUsers AS eu ON uu.UserName = eu.UserName AND uu.IntAccountId = eu.AccountId
        WHERE
            (
                eu.FirstName != uu.FirstName
                OR eu.LastName != uu.LastName
                OR eu.Email != uu.Email
                OR eu.GroupId != uu.GroupId
                OR eu.IsActive != uu.IsActive
            );

        INSERT INTO #UpdatedUsers
        SELECT
            eu.UserId, eu.CustomerId, eu.UserName, eu.FirstName, eu.LastName, eu.Email, eu.GroupId, eu.AccountId, 0 AS Active
        FROM #ExistingUsers AS eu
        WHERE
            NOT EXISTS (SELECT 1 FROM #UploadedUsers AS uu WHERE uu.IntAccountId = eu.AccountId AND uu.UserName = eu.UserName)
            AND eu.IsActive = 1;

        BEGIN TRANSACTION;

        UPDATE u
        SET
            u.Group_ID = uu.GroupId,
            u.IsActive = uu.IsActive,
            u.Update_Tms = GETDATE(),
            u.Update_UserID = CURRENT_USER
        FROM dbo.Users AS u
        JOIN #UpdatedUsers AS uu ON u.[User_ID] = uu.UserId

        UPDATE c
        SET
            c.Email = uu.Email,
            c.FirstName = uu.FirstName,
            c.LastName = uu.LastName
        FROM dbo.Customers AS c
        JOIN #UpdatedUsers AS uu ON c.Customer_ID = uu.CustomerId

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            uus.UserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'UPDATED' AS [Status],
            'Success: User was updated' AS [Message],
            uu.IntAccountId
        FROM #UploadedUsers AS uu
        JOIN #UpdatedUsers AS uus ON uus.UserName = uu.UserName AND uus.AccountId = uu.IntAccountId

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            eu.UserId,
            eu.UserName,
            '' AS SourceUserId,
            '' AS SourceUserName,
            eu.FirstName,
            eu.LastName,
            eu.Email,
            CASE
                WHEN eu.GroupId = @ManagerGroupId THEN 'Manager'
                WHEN eu.GroupId = @ClerkGroupId THEN 'Clerk'
                ELSE 'Unknown'
            END AS UserType,
            '' AS LocationId,
            '' AS Change,
            eu.AccountId,
            'DEACTIVATED' AS [Status],
            'Success: User was deactivated' AS [Message],
            eu.AccountId AS IntAccountId
        FROM #ExistingUsers AS eu
        WHERE
            NOT EXISTS (SELECT 1 FROM #UploadedUsers AS uu WHERE uu.IntAccountId = eu.AccountId AND uu.UserName = eu.UserName)
            AND eu.IsActive = 1;

        IF OBJECT_ID('tempdb..#NewUsers') IS NOT NULL
            BEGIN
                DROP TABLE #NewUsers;
            END;

        SELECT
            uu.UserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.GroupId,
            uu.AccountId,
            uu.IsActive
        INTO #NewUsers
        FROM #UploadedUsers AS uu
        WHERE
            NOT EXISTS (SELECT 1 FROM #ExistingUsers AS eu WHERE eu.AccountId = uu.IntAccountId AND eu.UserName = uu.UserName)
            AND NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uur.VidapayUserName = uu.UserName AND uur.IntAccountId = uu.IntAccountId)

        IF OBJECT_ID('tempdb..#InsertedCustomers') IS NOT NULL
            BEGIN
                DROP TABLE #InsertedCustomers;
            END;
        CREATE TABLE #InsertedCustomers
        (
            CustomerId INT NOT NULL,
            UserName VARCHAR(50) NOT NULL,
            AccountId INT NOT NULL
        )

        IF OBJECT_ID('tempdb..#InsertedUsers') IS NOT NULL
            BEGIN
                DROP TABLE #InsertedUsers;
            END;
        CREATE TABLE #InsertedUsers
        (
            UserId INT NOT NULL,
            UserName VARCHAR(50) NOT NULL,
            AccountId INT NOT NULL
        )

        MERGE INTO dbo.Customers AS c
        USING #NewUsers AS nu ON 1 = 0
        WHEN NOT MATCHED BY TARGET
            THEN
            INSERT (FirstName, LastName, Email, Address1, Address2, City, [State], Zip, Country, Phone, Fax)
            VALUES
                (
                    nu.FirstName,
                    nu.LastName,
                    nu.Email,
                    '',
                    '',
                    '',
                    '',
                    '',
                    '',
                    '',
                    ''
                )
        OUTPUT INSERTED.Customer_Id, nu.UserName, nu.AccountId INTO #InsertedCustomers (CustomerId, UserName, AccountId);

        INSERT INTO [dbo].[Users]
        (
            UserName,
            Account_ID,
            [Password],
            Group_Id,
            Status_ID,
            Subscribe,
            Return_Allowed,
            Report_Allowed,
            POS_AccessOnly_Flg,
            IsActive,
            Customer_ID,
            UserType_ID,
            CRM_Group_ID,
            EmailIsBad,
            IsPasswordExpired,
            User_Parent_ID,
            User_Tree,
            Created,
            Create_UserID,
            Update_Tms,
            Update_UserID
        )
        OUTPUT INSERTED.User_ID, INSERTED.UserName, INSERTED.Account_ID
        INTO #InsertedUsers
        SELECT
            nu.UserName,
            nu.AccountId,
            CONVERT(VARCHAR(255), NEWID()) AS [Password],
            nu.GroupId,
            1 AS Status_ID,
            0 AS Subscribe,
            1 AS Return_Allowed,
            1 AS Report_Allowed,
            0 AS POS_AccessOnly_Flg,
            nu.IsActive,
            ic.CustomerId,
            0 AS UserType_ID,
            0 AS CRM_Group_ID,
            0 AS EmailIsBad,
            0 AS IsPasswordExpired,
            0 AS User_Parent_ID,
            0 AS User_Tree,
            GETDATE() AS Created,
            CURRENT_USER AS Create_UserID,
            GETDATE() AS Update_Tms,
            CURRENT_USER AS Update_UserID
        FROM #NewUsers AS nu
        JOIN #InsertedCustomers AS ic ON ic.AccountId = nu.AccountId AND ic.UserName = nu.UserName

        INSERT #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            iu.UserId,
            uu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'CREATED' AS [Status],
            'Success: User was created' AS [Message],
            uu.IntAccountId
        FROM #InsertedUsers AS iu
        JOIN #UploadedUsers AS uu ON uu.IntAccountId = iu.AccountId AND iu.UserName = uu.UserName;

        INSERT INTO #UpsertUserResults
        (
            VidapayUserId,
            VidapayUserName,
            SourceUserId,
            SourceUserName,
            FirstName,
            LastName,
            Email,
            UserType,
            LocationId,
            Change,
            AccountId,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            eu.UserId,
            eu.UserName,
            uu.SourceUserId,
            uu.SourceUserName,
            uu.FirstName,
            uu.LastName,
            uu.Email,
            uu.UserType,
            uu.LocationId,
            uu.Change,
            uu.AccountId,
            'No Change' AS [Status],
            '' AS [Message],
            eu.AccountId AS IntAccountId
        FROM #UploadedUsers AS uu
        JOIN #ExistingUsers AS eu ON eu.UserName = uu.UserName AND eu.AccountId = uu.IntAccountId
        WHERE NOT EXISTS (SELECT 1 FROM #UpsertUserResults AS uur WHERE uur.VidapayUserName = uu.UserName AND uur.IntAccountId = uu.IntAccountId);

        COMMIT TRANSACTION;

        --Support for parent sproc
        IF OBJECT_ID('tempdb..#final') IS NOT NULL
            BEGIN
                INSERT INTO #final
                SELECT
                    VidapayUserId AS VidapayUserId,
                    VidapayUserName AS VidapayUserName,
                    SourceUserId AS SourceUserId,
                    SourceUserName AS SourceUserName,
                    FirstName AS FirstName,
                    LastName AS LastName,
                    Email AS Email,
                    UserType AS UserType,
                    LocationId AS LocationId,
                    Change AS Change,
                    AccountId AS AccountId,
                    [Status] AS [Status],
                    [Message] AS [Message]
                FROM #UpsertUserResults
            END
        ELSE
            BEGIN
                SELECT
                    VidapayUserId AS VidapayUserId,
                    VidapayUserName AS VidapayUserName,
                    SourceUserId AS SourceUserId,
                    SourceUserName AS SourceUserName,
                    FirstName AS FirstName,
                    LastName AS LastName,
                    Email AS Email,
                    UserType AS UserType,
                    LocationId AS LocationId,
                    Change AS Change,
                    AccountId AS AccountId,
                    [Status] AS [Status],
                    [Message] AS [Message]
                FROM #UpsertUserResults
            END
    END TRY
    BEGIN CATCH
        ROLLBACK;
        DELETE uu
        FROM Upload.tblUploadUsers AS uu
        WHERE uu.ProcessAccountId = @TopParentAccountId;
        THROW;
    END CATCH
END;
